# frozen_string_literal: true

class ApplyMate::Ai::AiHandler
  def self.call(prompt_instance:, response_schema_class:, ai_integration:)
    # 1. Initialize Client
    client = build_client(ai_integration)

    # 2. Combine Prompt + Schema Instructions
    full_prompt = <<~TEXT
      #{prompt_instance.call}

      #{response_schema_class.format_instructions}
    TEXT

    # 3. Request
    raw_response = client.ask(full_prompt)

    # 4. Parse via Schema
    response_schema_class.extract(raw_response)
  end

  private

  def self.build_client(ai_integration)
    client_class = AiIntegration::PROVIDER_CLIENTS.fetch(ai_integration.provider)
    client_class.new(api_key: ai_integration.api_key, host: ai_integration.host, model: ai_integration.model)
  end
end
