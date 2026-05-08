# frozen_string_literal: true

class Apply::Ai::ResponseSchema::Browser::CheckSubmitResult < ApplyMate::Ai::ResponseSchema::Base
  def self.format_instructions
    <<~INSTRUCTIONS
      Return a JSON object with exactly two keys:
      - "success": boolean — true if the submission appears successful, false if it clearly failed
      - "reason": string — one sentence explaining your conclusion

      Wrap the JSON in a ```json code block. No extra text outside the code block.
    INSTRUCTIONS
  end

  def self.extract(raw_response)
    return { 'success' => true, 'reason' => 'No AI response' } if raw_response.blank?

    match    = raw_response.match(/```json\s+(.*?)\s+```/m)
    json_str = match ? match[1] : raw_response
    json_str = json_str.match(/(\{.*\})/m)&.[](0) || json_str

    JSON.parse(json_str).with_indifferent_access
  rescue StandardError => e
    Rails.logger.error("CheckSubmitResult schema parse error: #{e.message}")
    { 'success' => true, 'reason' => 'Could not parse AI response' }
  end
end
