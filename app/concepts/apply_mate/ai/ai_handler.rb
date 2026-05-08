# frozen_string_literal: true

class ApplyMate::Ai::AiHandler
  def self.call(prompt_instance:, response_schema_class:, ai_integration:)
    client = build_client(ai_integration)

    full_prompt = <<~TEXT
      #{prompt_instance.call}

      #{response_schema_class.format_instructions}
    TEXT

    response_schema_class.extract(client.ask(full_prompt))
  end

  private

  def self.build_client(ai_integration)
    client_class = AiIntegration::PROVIDER_CLIENTS.fetch(ai_integration.provider)
    client_class.new(api_key: ai_integration.api_key, host: ai_integration.host, model: ai_integration.model)
  end
end
