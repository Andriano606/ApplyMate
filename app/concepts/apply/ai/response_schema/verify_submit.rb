# frozen_string_literal: true

# { submitted, confidence, quote } for Apply::Ai::Prompt::VerifySubmit. VerifySubmit counts it as one extra signal
# only when submitted, confidence >= VerifySubmit::AI_MIN_CONFIDENCE and the quote is really in the page text.
class Apply::Ai::ResponseSchema::VerifySubmit < ApplyMate::Ai::ResponseSchema::Json
  def self.kind
    :verify
  end

  def self.json_schema
    {
      type: 'object',
      required: %w[submitted confidence quote],
      properties: {
        submitted: { type: 'boolean' },
        confidence: { type: 'number', minimum: 0, maximum: 1 },
        quote: { type: 'string' }
      },
      additionalProperties: false
    }
  end

  def self.format_instructions
    <<~INSTRUCTIONS
      Response format:
      Return one JSON object: {"submitted": true|false, "confidence": <0..1>, "quote": "<exact sentence from the page text>"}.
      "quote" must be copied verbatim from the page text; use "" when there is nothing to quote.
      Wrap the JSON in a ```json code block. No extra text outside the code block.
    INSTRUCTIONS
  end
end
