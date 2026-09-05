# frozen_string_literal: true

# Assigns a canonical role to every form field. Deterministic sources first
# (scraper ROLE_OVERRIDES, input type, autocomplete) — the AI is called only for
# the fields that remain ambiguous, and an AI answer outside the vocabulary
# degrades to custom_question. Runs under the filling_form status umbrella.
class Apply::Operation::Ai::MapFields < Apply::Operation::Base
  def start_status
    :filling_form
  end

  def error_status
    :failed_filling_form
  end

  private

  def run!(apply:, **)
    inputs = apply.inputs
    raise 'No form inputs to map' if inputs.blank?

    overrides = apply.vacancy.source.build_scraper.role_overrides

    mapped = inputs.map do |input|
      input = input.to_h.stringify_keys
      role  = input['role'].presence || Apply::CanonicalRoles.deterministic_role_for(input, overrides:)
      input.merge(
        'role'        => role,
        'fingerprint' => input['fingerprint'].presence || Apply::FieldFingerprint.call(input)
      )
    end

    ambiguous = mapped.select { |input| input['role'].blank? }
    mapped    = apply_ai_mapping(apply, mapped, ambiguous) if ambiguous.any?

    apply.update!(inputs: mapped)
  end

  def apply_ai_mapping(apply, mapped, ambiguous)
    mapping = ApplyMate::Ai::AiHandler.call(
      prompt_instance:       Apply::Ai::Prompt::MapFields.new(ambiguous),
      response_schema_class: Apply::Ai::ResponseSchema::MapFields,
      ai_integration:        apply.ai_integration
    )
    raise 'AI returned an empty field mapping' if mapping.blank?

    mapped.map do |input|
      next input if input['role'].present?

      role = mapping[input['fingerprint']].to_s
      input.merge('role' => Apply::CanonicalRoles::ALL.include?(role) ? role : 'custom_question')
    end
  end
end
