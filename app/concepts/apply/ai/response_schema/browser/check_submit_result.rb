# frozen_string_literal: true

class Apply::Ai::ResponseSchema::Browser::CheckSubmitResult < ApplyMate::Ai::ResponseSchema::Json
  def self.kind
    :verify
  end

  def self.json_schema
    {
      type:       'object',
      required:   %w[success reason],
      properties: {
        success: { type: 'boolean' },
        reason:  { type: 'string' }
      }
    }
  end

  def self.format_instructions
    <<~INSTRUCTIONS
      Return a JSON object with exactly two keys:
      - "success": boolean — true if the submission appears successful, false if it clearly failed
      - "reason": string — one sentence explaining your conclusion

      Wrap the JSON in a ```json code block. No extra text outside the code block.
    INSTRUCTIONS
  end
end
