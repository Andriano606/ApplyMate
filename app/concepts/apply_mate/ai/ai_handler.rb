# frozen_string_literal: true

class ApplyMate::Ai::AiHandler
  include ApplyMate::Logging

  # The parsed answer and the provider's token usage (ApplyMate::Ai::Usage, nil counts when unreported).
  Outcome = Data.define(:data, :usage)

  # The parsed answer only: the callers outside the apply engine (the engine goes through Engine::CallAi -> #complete).
  def self.call(prompt_instance:, response_schema_class:, ai_integration:)
    new.call(prompt_instance:, response_schema_class:, ai_integration:)
  end

  def self.complete(prompt_instance:, response_schema_class:, ai_integration:, request_options: {})
    new.complete(prompt_instance:, response_schema_class:, ai_integration:, request_options:)
  end

  def call(prompt_instance:, response_schema_class:, ai_integration:)
    complete(prompt_instance:, response_schema_class:, ai_integration:).data
  end

  # request_options: system:, images:, timeout:, retries: (merged into Request.for). A nil timeout is the client's
  # declared latency for the kind (Client::Base.call_seconds), nil retries the kind's default.
  def complete(prompt_instance:, response_schema_class:, ai_integration:, request_options: {})
    client_class = AiIntegration::PROVIDER_CLIENTS.fetch(ai_integration.provider)
    client = client_class.new(api_key: ai_integration.api_key, host: ai_integration.host, model: ai_integration.model)
    kind = response_schema_class.kind
    request_options = request_options.merge(timeout: request_options[:timeout] || client_class.call_seconds(kind))

    full_prompt = <<~TEXT
      #{prompt_instance.call}

      #{response_schema_class.format_instructions}
    TEXT

    # format_instructions stay in the prompt for every client: they carry the field semantics, and
    # ResponseSchema::Json parses both raw (native schema) and fenced (text-mode) JSON.
    json_schema = response_schema_class.json_schema if response_schema_class.native_schema?
    request = ApplyMate::Ai::Request.for(kind:, text: full_prompt, json_schema:, **request_options)
    response = client.complete(request)
    log("#{client.class.name} kind=#{kind} input_tokens=#{response.usage.input_tokens.inspect} " \
        "output_tokens=#{response.usage.output_tokens.inspect}")
    Outcome.new(data: extract(response_schema_class, response), usage: response.usage)
  end

  private

  # An unusable answer still cost tokens: the error carries them (InvalidResponse#usage) to Engine::CallAi.
  def extract(response_schema_class, response)
    response_schema_class.extract(response.text)
  rescue ApplyMate::Ai::ResponseSchema::Json::InvalidResponse => e
    e.usage = response.usage
    raise
  end
end
