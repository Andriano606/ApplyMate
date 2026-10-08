# frozen_string_literal: true

# What a review approval is bound to (design §8.2): SHA256 of the canonical JSON of the answers, value and source
# only (confidence and any bookkeeping do not matter), keys sorted at every level. model = hex digest.
class Apply::Operation::Answer::Digest < ApplyMate::Operation::Base
  def perform!(answers:, **)
    skip_authorize
    canonical = answers.to_h.sort_by { |id, _answer| id.to_s }.to_h do |id, answer|
      [ id.to_s, { 'value' => sorted(answer.to_h.with_indifferent_access[:value].as_json),
                   'source' => answer.to_h.with_indifferent_access[:source] } ]
    end
    self.model = ::Digest::SHA256.hexdigest(canonical.to_json)
  end

  private

  def sorted(value)
    case value
    when Hash then value.sort_by { |key, _| key.to_s }.to_h { |key, inner| [ key, sorted(inner) ] }
    when Array then value.map { |inner| sorted(inner) }
    else value
    end
  end
end
