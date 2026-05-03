# frozen_string_literal: true

class Apply::Operation::Ai::FillForm < ApplyMate::Operation::Base
  def perform!(apply:, **)
    self.model = apply

    return if apply.error.present? || apply.form_data.blank?

    apply.update!(status: :filling_form)
    Apply::TurboHandler::StatusUpdate.broadcast(apply.vacancy)

    filled_form_hash = call_ai(apply)

    if filled_form_hash.present?
      filled_form_data = merge_form(apply.form_data, filled_form_hash)
      apply.update!(filled_form_data:, status: :pending)
    else
      apply.update!(status: :failed_filling_form, error: "AI returned empty payload or invalid JSON: #{ai_values_json}")
      raise 'Invalid AI response'
    end

    Apply::TurboHandler::StatusUpdate.broadcast(apply.vacancy)
  rescue StandardError => e
    apply.update!(status: :failed_filling_form, error: e.message)
    Apply::TurboHandler::StatusUpdate.broadcast(apply.vacancy)
    raise
  end

  private

  def call_ai(apply)
    ApplyMate::Ai::AiHandler.call(
      prompt_instance: Apply::Ai::Prompt::Djinni::FillForm.new(apply),
      response_schema_class: Apply::Ai::ResponseSchema::Djinni::FillForm,
      ai_integration: apply.ai_integration
    )
  end

  def merge_form(form_data, filled_form_hash)
    inputs = (form_data['inputs'] || form_data[:inputs] || []).map do |input|
      input = input.with_indifferent_access
      ai_value = filled_form_hash[input['name']]
      ai_value.present? ? input.merge('value' => ai_value.to_s) : input
    end
    form_data.merge('inputs' => inputs)
  end
end
