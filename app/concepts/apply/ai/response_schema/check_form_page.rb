# frozen_string_literal: true

class Apply::Ai::ResponseSchema::CheckFormPage < ApplyMate::Ai::ResponseSchema::Base
  def self.format_instructions
    <<~INSTRUCTIONS
      Return a JSON object with exactly four keys:
      - "has_form": boolean — true if an application form is already visible on the page
      - "trigger_selector": string or null — CSS selector of the button/link that reveals a hidden form (when has_form is false), null otherwise
      - "form_url": string or null — URL of another page containing the form (when has_form is false and no trigger_selector), null otherwise
      - "form_selector": string or null — CSS selector of the element wrapping all application inputs (when has_form is true), null otherwise

      Wrap the JSON in a ```json code block. No extra text outside the code block.
    INSTRUCTIONS
  end

  def self.extract(raw_response)
    return { 'has_form' => false, 'trigger_selector' => nil, 'form_url' => nil, 'form_selector' => nil } if raw_response.blank?

    match    = raw_response.match(/```json\s+(.*?)\s+```/m)
    json_str = match ? match[1] : raw_response
    json_str = json_str.match(/(\{.*\})/m)&.[](0) || json_str

    JSON.parse(json_str).with_indifferent_access
  rescue StandardError => e
    Rails.logger.error("CheckFormPage schema parse error: #{e.message}")
    raise "Failed to parse AI CheckFormPage response: #{e.message}"
  end
end
