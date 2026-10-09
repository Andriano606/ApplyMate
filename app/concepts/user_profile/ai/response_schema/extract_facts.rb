# frozen_string_literal: true

class UserProfile::Ai::ResponseSchema::ExtractFacts < ApplyMate::Ai::ResponseSchema::Json
  FACT_KEYS = %w[
    full_name first_name last_name email phone linkedin github location country salary notice_period
    years_experience work_authorization
  ].freeze
  KEYS = (FACT_KEYS + %w[languages]).freeze

  def self.kind
    :answers
  end

  def self.json_schema
    properties = FACT_KEYS.index_with { { type: %w[string null] } }
    properties['languages'] = { type: %w[array null], items: { type: 'string' } }

    { type: 'object', properties: properties.symbolize_keys, additionalProperties: false }
  end

  def self.format_instructions
    <<~INSTRUCTIONS
      Return a JSON object with exactly these keys: #{KEYS.join(', ')}.
      Omit a key or use null when the CV does not state it. Every value is a string; "languages" is an array of strings or null.
      Never guess: only use facts written in the CV. Wrap the JSON in a ```json code block. No extra text outside the code block.
    INSTRUCTIONS
  end

  # Keys with a value only (null / blank dropped).
  def self.extract(raw_response)
    super.slice(*KEYS).compact_blank.to_h
  end
end
