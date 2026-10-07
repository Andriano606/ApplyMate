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

  # Deliberately lenient until phase 1 (design §15 rows 0/1): an unusable verdict still counts as
  # success. A client EmptyResponse (no text at all) gets the same treatment in
  # Apply::Operation::SendApply::Browser#verify_submit. Phase 1 replaces both with
  # claim + submit_unverified, and this override goes away.
  def self.extract(raw_response)
    super
  rescue InvalidResponse
    { 'success' => true, 'reason' => 'Could not parse AI response' }.with_indifferent_access
  end
end
