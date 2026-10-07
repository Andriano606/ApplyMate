# frozen_string_literal: true

class Apply::Ai::ResponseSchema::CheckFormPage < ApplyMate::Ai::ResponseSchema::Json
  def self.kind
    :navigate
  end

  def self.json_schema
    {
      type:                 'object',
      required:             %w[has_form trigger_selector form_url form_selector],
      properties:           {
        has_form:         { type: 'boolean' },
        trigger_selector: { type: %w[string null] },
        form_url:         { type: %w[string null] },
        form_selector:    { type: %w[string null] }
      },
      additionalProperties: false
    }
  end

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
end
