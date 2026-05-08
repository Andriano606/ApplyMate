# frozen_string_literal: true

class Apply::Operation::Ai::FillForm < Apply::Operation::Base
  def start_status
    :filling_form
  end

  def error_status
    :failed_filling_form
  end

  private

  def run!(apply:, prompt_class:, schema_class:, **)
    filled_form_hash = ApplyMate::Ai::AiHandler.call(
      prompt_instance:       prompt_class.new(apply),
      response_schema_class: schema_class,
      ai_integration:        apply.ai_integration
    )

    raise "AI returned empty payload or invalid JSON: #{filled_form_hash.inspect}" if filled_form_hash.blank?

    inputs = (apply.inputs || []).map do |input|
      input    = input.with_indifferent_access
      ai_value = filled_form_hash[input['name']]
      ai_value.present? ? input.merge('value' => ai_value.to_s) : input
    end

    apply.update!(filled_inputs: inputs)
  end
end
