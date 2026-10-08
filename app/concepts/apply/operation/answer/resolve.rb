# frozen_string_literal: true

# The answers of an application (design §8.1), without a browser. Per fillable field, in this order:
#   platform.answer_override -> classify (the semantic is persisted back onto the field) ->
#   password: Halt(:login_required) -> demographic: the user's explicit fact, else the "decline to self-identify"
#   option, else nothing (optional) / Halt(:missing_profile_fact) -> legal_status: facts only, else the same ->
#   profile facts -> consent (ResolveConsent) -> cv (FileRef); another file field: missing (never the AI) ->
#   the rest in ONE AI call.
# The sensitive semantics never reach the AI. Answers of an earlier review (source 'user') are kept as they are. The AI
# answers are validated field by field (CoerceValue); an invalid set is asked once more with the error list, a second
# failure is Halt(:invalid_ai_output). A field whose `condition` is unmet gets no answer.
#
# model   { field_id => { 'value' =>, 'source' =>, 'confidence' => } }
# result[:fields]   the field list with `semantic` filled in
class Apply::Operation::Answer::Resolve < ApplyMate::Operation::Base
  MAX_ATTEMPTS = 2
  ASK_AI = :ask_ai

  def perform!(ctx:, **)
    skip_authorize
    @apply = ctx.apply
    @platform = ctx.platform
    fields = ctx.field_list.map { |field| field.with(semantic: classify(field)) }
    answers, open_fields = resolve_known(fields)
    answers.merge!(ask_ai(open_fields)) if open_fields.any?
    drop_unmet_conditions(fields, answers)
    ctx.trace(:answers_resolved, total: answers.size, ai: open_fields.size)
    self.model = answers
    result[:fields] = fields
  end

  private

  attr_reader :apply, :platform

  def classify(field)
    Apply::Operation::Answer::Classify.call(field:, platform:).model
  end

  def resolve_known(fields)
    kept = apply.answers || {}
    answers = {}
    open_fields = []
    fields.each do |field|
      next unless field.fillable?
      next if condition_unmet?(field, answers, unknown: false)

      if kept.dig(field.id, 'source') == 'user'
        answers[field.id] = kept[field.id]
        next
      end

      outcome = deterministic(field)
      if outcome == ASK_AI
        open_fields << field
      elsif outcome
        answers[field.id] = outcome
      end
    end
    [ answers, open_fields ]
  end

  def deterministic(field)
    override = platform&.answer_override(field)
    return answer(override, 'override') unless override.nil?

    case field.semantic
    when 'password' then halt(:login_required, field.id)
    when 'demographic' then demographic(field)
    when 'legal_status' then legal_status(field)
    when 'consent_required' then consent(field)
    when 'marketing_opt_in' then nil
    when 'cv' then answer(Apply::Operation::Answer::FileRef.cv.as_json, 'fact')
    else fact(field)
    end
  end

  def demographic(field)
    fact_answer(field, 'demographic') || decline(field) || missing(field)
  end

  def legal_status(field)
    fact_answer(field, 'legal_status') || missing(field)
  end

  # The user's own fact, if it fits the field.
  def fact_answer(field, semantic)
    value = Apply::Operation::Answer::ResolveFact.call(semantic:, apply:).model
    return if value.blank?

    coerced = Apply::Operation::Answer::CoerceValue.call(field: field.with(required: false), value:)
    answer(coerced.model, 'fact') if coerced[:error].nil? && !coerced.model.nil?
  end

  def decline(field)
    label = Apply::Operation::Answer::Classify.option_label_for(field, Apply::Operation::Answer::Classify::DECLINE)
    answer(Apply::Operation::Answer::CoerceValue.call(field:, value: label).model, 'policy') if label
  end

  def missing(field)
    halt(:missing_profile_fact, field.id) if field.required
    nil
  end

  # A file field the platform maps away from 'cv' (a cover-letter upload, a portfolio): only the apply's own files
  # (FileRef) are ever uploaded, so it is missing, never an AI answer (an AI string would become an upload path).
  def fact(field)
    return missing(field) if field.file?

    fact_answer(field, field.semantic) || ASK_AI
  end

  def consent(field)
    outcome = Apply::Operation::Answer::ResolveConsent.call(field:, user: apply.user)
    return outcome.model if outcome.model
    return unless outcome[:reason] == :review && field.required

    # No affirmative option: the user chooses in the review form (an edit becomes source 'user').
    { 'value' => nil, 'source' => 'policy_pending', 'confidence' => 0.0 }
  end

  def answer(value, source)
    { 'value' => value, 'source' => source, 'confidence' => 1.0 }
  end

  def halt(code, detail)
    raise Apply::Operation::Engine::Halt.new(code, detail:)
  end

  # ---------- AI ----------

  def ask_ai(fields)
    errors = []
    MAX_ATTEMPTS.times do
      answers, errors = attempt(fields, errors)
      return answers if errors.empty?
    end
    halt(:invalid_ai_output, errors.first(5).join('; '))
  end

  def attempt(fields, previous_errors)
    raw = ApplyMate::Ai::AiHandler.call(
      prompt_instance:       Apply::Ai::Prompt::AnswerFields.new(apply:, fields:, platform:, errors: previous_errors),
      response_schema_class: Apply::Ai::ResponseSchema::AnswerFields,
      ai_integration:        apply.ai_integration
    )
    validate_answers(fields, raw)
  rescue ApplyMate::Ai::ResponseSchema::Json::InvalidResponse => e
    [ {}, [ e.message ] ]
  end

  def validate_answers(fields, raw)
    answers = {}
    errors = []
    fields.each do |field|
      entry = raw[field.id].to_h.with_indifferent_access
      coerced = Apply::Operation::Answer::CoerceValue.call(field:, value: entry[:value])
      if coerced[:error]
        errors << "#{field.id}: #{coerced[:error]}"
      elsif !coerced.model.nil?
        answers[field.id] = { 'value' => coerced.model, 'source' => 'ai', 'confidence' => entry[:confidence].to_f.clamp(0.0, 1.0) }
      end
    end
    [ answers, errors ]
  end

  # ---------- conditions ----------

  # unknown: how to treat a condition whose field has no answer (yet): false while resolving, true at the end.
  def condition_unmet?(field, answers, unknown:)
    condition = field.condition
    return false if condition.blank?

    given = answers.dig(condition['field'], 'value')
    return unknown if given.nil?

    Array(given).none? { |value| Apply::Operation::Engine::MatchOption.same?(value.to_s, condition['equals']) }
  end

  def drop_unmet_conditions(fields, answers)
    fields.each do |field|
      answers.delete(field.id) if answers.key?(field.id) && condition_unmet?(field, answers, unknown: true)
    end
  end
end
