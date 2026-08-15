# frozen_string_literal: true

class Apply::Ai::ResponseSchema::PlanActions < ApplyMate::Ai::ResponseSchema::Base
  def self.format_instructions
    <<~INSTRUCTIONS
      Return a JSON object with exactly three keys:
      - "actions": array of action objects ({"op", "handle", "role"?, "value"?, "purpose"?})
      - "status": "in_progress" or "blocked"
      - "blocked_reason": null, "captcha_v2", "requires_account", "login_wall" or "other"

      Wrap the JSON in a ```json code block. No extra text outside the code block.
    INSTRUCTIONS
  end

  def self.extract(raw_response)
    return { 'actions' => [], 'status' => 'blocked', 'blocked_reason' => 'other' } if raw_response.blank?

    match    = raw_response.match(/```json\s+(.*?)\s+```/m)
    json_str = match ? match[1] : raw_response
    json_str = json_str.match(/(\{.*\})/m)&.[](0) || json_str

    parsed = JSON.parse(json_str).with_indifferent_access
    parsed['actions'] ||= []
    parsed
  rescue StandardError => e
    Rails.logger.error("PlanActions schema parse error: #{e.message}")
    raise "Failed to parse AI PlanActions response: #{e.message}"
  end
end
