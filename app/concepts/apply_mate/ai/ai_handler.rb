# frozen_string_literal: true

class ApplyMate::Ai::AiHandler
  include ApplyMate::Logging

  def self.call(prompt_instance:, response_schema_class:, ai_integration:)
    new.call(prompt_instance:, response_schema_class:, ai_integration:)
  end

  def call(prompt_instance:, response_schema_class:, ai_integration:)
    client = build_client(ai_integration)
    kind = response_schema_class.kind

    full_prompt = <<~TEXT
      #{prompt_instance.call}

      #{response_schema_class.format_instructions}
    TEXT

    # format_instructions stay in the prompt for every client: they carry the field semantics, and
    # ResponseSchema::Json parses both raw (native schema) and fenced (text-mode) JSON.
    json_schema = response_schema_class.json_schema if response_schema_class.native_schema?
    response = client.complete(ApplyMate::Ai::Request.for(kind:, text: full_prompt, json_schema:))
    log("#{client.class.name} kind=#{kind} input_tokens=#{response.usage.input_tokens.inspect} " \
        "output_tokens=#{response.usage.output_tokens.inspect}")
    response_schema_class.extract(response.text)
  end

  private

  def build_client(ai_integration)
    client_class = AiIntegration::PROVIDER_CLIENTS.fetch(ai_integration.provider)
    client_class.new(api_key: ai_integration.api_key, host: ai_integration.host, model: ai_integration.model)
  end
end
