# frozen_string_literal: true

class ApplyMate::Ai::ResponseSchema::Base
  # One of ApplyMate::Ai::Request::KINDS (:navigate, :answers, :verify, :cv). AiHandler sizes the
  # request (max_output_tokens, timeout) from it.
  def self.kind
    raise NotImplementedError, "#{name} must declare .kind"
  end

  # JSON-Schema Hash validated by ResponseSchema::Json subclasses; nil for non-JSON answers
  # (e.g. GenerateCv HTML). Declared here so AiHandler can ask any schema class.
  def self.json_schema
    nil
  end

  # True when json_schema is sent to the provider natively (Gemini responseSchema, Ollama format).
  def self.native_schema?
    false
  end

  def self.format_instructions
    raise NotImplementedError
  end

  def self.extract(raw_response)
    raise NotImplementedError
  end
end
