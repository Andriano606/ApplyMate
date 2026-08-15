# frozen_string_literal: true

# Pipeline step wrapping Apply::ValueResolver: resolves every mapped input to a
# value (bank / profile / constants / one AI batch) and stores filled_inputs.
class Apply::Operation::ResolveValues < Apply::Operation::Base
  def start_status
    :filling_form
  end

  def error_status
    :failed_filling_form
  end

  private

  def run!(apply:, prompt_class:, schema_class:, **)
    inputs = apply.inputs
    raise 'No form inputs to resolve' if inputs.blank?

    resolver = Apply::ValueResolver.new(apply:, prompt_class:, schema_class:)
    apply.update!(filled_inputs: resolver.resolve(inputs))
  end
end
