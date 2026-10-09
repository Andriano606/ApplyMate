# frozen_string_literal: true

# The one place that turns an AI text answer into validated JSON. Subclasses declare `json_schema`
# and `format_instructions`; `extract` parses (fence/prose tolerant) and validates, raising
# InvalidResponse on a blank, unparseable or schema-violating answer.
class ApplyMate::Ai::ResponseSchema::Json < ApplyMate::Ai::ResponseSchema::Base
  # `usage`: the provider's token usage of the call that produced the answer (ApplyMate::Ai::Usage), set by
  # AiHandler#complete so a caller still accounts for the tokens an unusable answer cost; nil when raised elsewhere.
  class InvalidResponse < StandardError
    attr_accessor :usage
  end

  FENCE = /```[a-z]*[ \t]*\n?(.*?)```/mi

  # Top-level `type: 'object'` (extract returns a HashWithIndifferentAccess).
  # JSON-Schema subset (symbol keys): type, properties, required, items, enum, minLength,
  # additionalProperties; nullable fields as `type: %w[string null]`. The json-schema gem has no
  # draft-7 validator; draft-6 covers exactly this subset with identical semantics.
  def self.json_schema
    raise NotImplementedError, "#{name} must declare .json_schema"
  end

  # Gemini's responseSchema needs fixed keys, so a schema that only declares additionalProperties
  # (dynamic keys, e.g. form input names) is used for validation here but never sent natively.
  def self.native_schema?
    json_schema.with_indifferent_access[:properties].present?
  end

  def self.extract(raw_response)
    validate!(parse(raw_response)).with_indifferent_access
  end

  # Prefers the inner text of a ``` / ```json fence, then narrows to the outermost JSON object: from
  # the first `{` to the last `}`. Objects only, because every schema is top-level `type: 'object'`;
  # a `[` in the prose (e.g. a CSS selector like `a[href*=apply]`) must not be taken as the start.
  # Native-schema answers (raw JSON) and text-mode answers (fenced, prose-wrapped) both pass here.
  def self.parse(raw_response)
    raise InvalidResponse, 'blank AI response' if raw_response.blank?

    candidate = raw_response[FENCE, 1].presence || raw_response
    start = candidate.index('{')
    finish = start && candidate.rindex('}')
    candidate = candidate[start..finish] if finish && finish > start

    ::JSON.parse(candidate)
  rescue ::JSON::ParserError => e
    raise InvalidResponse, "AI response is not valid JSON: #{e.message}"
  end
  private_class_method :parse

  # parse_data: false — with the gem default a String datum is parsed again and, failing that,
  # opened as a URI or file path; AI output must never reach URI.open / File.read.
  def self.validate!(data)
    errors = ::JSON::Validator.fully_validate(json_schema.deep_stringify_keys, data, version: :draft6, parse_data: false)
    raise InvalidResponse, errors.join('; ') if errors.any?

    data
  end
  private_class_method :validate!
end
