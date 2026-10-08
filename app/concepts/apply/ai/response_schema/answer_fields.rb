# frozen_string_literal: true

# { field_id => { value, confidence } } for Apply::Ai::Prompt::AnswerFields. The keys are the form's own field ids, so
# there are no fixed properties: validated here, never sent natively (native_schema? false). A value is text, a
# number, a boolean, a list of option labels or null; confidence is 0..1.
class Apply::Ai::ResponseSchema::AnswerFields < ApplyMate::Ai::ResponseSchema::Json
  def self.kind
    :answers
  end

  def self.json_schema
    {
      type: 'object',
      additionalProperties: {
        type: 'object',
        properties: {
          value: { type: %w[string number boolean array null], items: { type: 'string' } },
          confidence: { type: 'number', minimum: 0, maximum: 1 }
        },
        required: %w[value confidence],
        additionalProperties: false
      }
    }
  end

  def self.format_instructions
    <<~INSTRUCTIONS
      Response format:
      Return one JSON object. Each key is a field id from the list; each value is {"value": ..., "confidence": ...}.
      "value" is a string, a number, true/false for a checkbox, a list of option labels for a multiple choice, or null when you cannot answer.
      For fields with options use the label of one option exactly as listed. Respect max_length.
      "confidence" is a number from 0 to 1: how well the candidate's experience supports the answer.
      Do not include file fields. Wrap the JSON in a ```json code block. No extra text outside the code block.
    INSTRUCTIONS
  end
end
