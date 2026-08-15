# frozen_string_literal: true

class Apply::Ai::ResponseSchema::MapFields < ApplyMate::Ai::ResponseSchema::Base
  def self.format_instructions
    <<~INSTRUCTIONS
      Return a JSON object where each key is a field id (the value in square
      brackets) and each value is exactly one role name from the vocabulary.
      Include every listed field. No extra keys, no explanations.

      Wrap the JSON in a ```json code block.
    INSTRUCTIONS
  end

  def self.extract(raw_response)
    return {} if raw_response.blank?

    match    = raw_response.match(/```json\s+(.*?)\s+```/m)
    json_str = match ? match[1] : raw_response
    json_str = json_str.match(/(\{.*\})/m)&.[](0) || json_str

    JSON.parse(json_str).with_indifferent_access
  rescue StandardError => e
    Rails.logger.error("MapFields schema parse error: #{e.message}")
    raise "Failed to parse AI MapFields response: #{e.message}"
  end
end
