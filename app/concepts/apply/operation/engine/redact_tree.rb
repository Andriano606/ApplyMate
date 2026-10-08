# frozen_string_literal: true

# Redact applied to every string leaf of a Hash / Array tree (apply_steps.result and trace): keys and non-string
# leaves are kept as they are. model = the redacted copy (nil stays nil).
class Apply::Operation::Engine::RedactTree < ApplyMate::Operation::Base
  def perform!(value:, apply: nil, **)
    skip_authorize
    self.model = walk(value, apply)
  end

  private

  def walk(value, apply)
    case value
    when Hash then value.transform_values { |leaf| walk(leaf, apply) }
    when Array then value.map { |leaf| walk(leaf, apply) }
    when String then Apply::Operation::Engine::Redact.call(text: value, apply:).model
    else value
    end
  end
end
