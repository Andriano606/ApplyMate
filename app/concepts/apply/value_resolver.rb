# frozen_string_literal: true

# Resolves field values from canonical roles. Used by the ResolveValues pipeline
# step (whole form at once) and by the External::Generic loop (fields appearing
# mid-flow). Resolution order per field: constants → hidden passthrough →
# cv_file (left to the CV step) → AnswerBank by role → profile defaults
# (name/email — never AI-generated) → AnswerBank by normalized question → one
# batched AI call for the rest. AI answers are cached back (source:
# ai_generated); cover_letter is vacancy-specific and is not cached.
class Apply::ValueResolver
  def initialize(apply:, prompt_class:, schema_class:)
    @apply        = apply
    @prompt_class = prompt_class
    @schema_class = schema_class
  end

  # Returns the fields with 'value' filled in. Fields it cannot answer without
  # generation are batched into a single AI call.
  def resolve(fields)
    @to_generate = []

    resolved = fields.map { |field| resolve_field(field.to_h.stringify_keys) }
    resolved = merge_generated(resolved, generate_batch) if @to_generate.any?
    resolved
  end

  private

  def resolve_field(field)
    role = field['role'].to_s

    return field if field['type'] == 'file' || role == 'cv_file'
    return field if role == 'hidden_passthrough' || field['type'] == 'hidden'

    constant = Apply::CanonicalRoles::CONSTANT_VALUES[role]
    return field.merge('value' => constant) unless constant.nil?

    value = bank_value(role, field) || profile_default(role)
    return field.merge('value' => value) if value.present?

    @to_generate << field
    field
  end

  def bank_value(role, field)
    return nil if role.blank?

    if role == 'custom_question'
      question = normalized_question(field)
      return nil if question.blank?

      bank.find_by(role: 'custom_question', question:)&.answer
    else
      bank.find_by(role:)&.answer
    end
  end

  # Contact data must come from the profile, never from AI generation — the
  # vacancy context contains nothing to derive it from.
  def profile_default(role)
    case role
    when 'full_name' then @apply.user_profile.name
    when 'email'     then @apply.user.email
    end
  end

  def generate_batch
    answers = ApplyMate::Ai::AiHandler.call(
      prompt_instance:       @prompt_class.new(@apply, @to_generate),
      response_schema_class: @schema_class,
      ai_integration:        @apply.ai_integration
    )
    raise "AI returned empty payload or invalid JSON: #{answers.inspect}" if answers.blank?

    answers
  end

  def merge_generated(resolved, answers)
    generated_fingerprints = @to_generate.map { |i| i['fingerprint'] }.to_set

    resolved.map do |field|
      next field unless generated_fingerprints.include?(field['fingerprint'])

      value = answers[field['fingerprint']]
      next field if value.blank?

      cache_answer(field, value.to_s)
      field.merge('value' => value.to_s)
    end
  end

  def cache_answer(field, value)
    role = field['role'].to_s
    return if role == 'cover_letter' # vacancy-specific, never reusable

    if role.blank? || role == 'custom_question'
      question = normalized_question(field)
      return if question.blank?

      bank.find_or_create_by!(role: 'custom_question', question:) do |entry|
        entry.answer = value
        entry.source = :ai_generated
      end
    else
      bank.find_or_create_by!(role:) do |entry|
        entry.answer = value
        entry.source = :ai_generated
      end
    end
  end

  def normalized_question(field)
    text = field['accessible_name'].presence || field['label'].presence ||
           field['placeholder'].presence || field['name']
    AnswerBank.normalize_question(text)
  end

  def bank
    @apply.user_profile.answer_banks
  end
end
