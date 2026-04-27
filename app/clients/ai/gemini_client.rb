# frozen_string_literal: true

class Ai::GeminiClient < Ai::BaseClient
  MODELS_ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/models'

  def initialize(api_key:, model: 'gemini-2.5-flash', **)
    @client = Gemini.new(
      credentials: { service: 'generative-language-api', api_key: },
      options: { model:, server_sent_events: true  }
    )
  end

  def ask(text)
    result = @client.generate_content({ contents: [ { parts: [ { text: } ] } ] })
    result.dig('candidates', 0, 'content', 'parts', 0, 'text')
  rescue StandardError => e
    Rails.logger.error "Gemini API failure: #{e.message}"
    raise e
  end

  def self.validate_api_key!(api_key:)
    response = Faraday.get(MODELS_ENDPOINT, { key: api_key })
    raise 'invalid_api_key' unless response.success?
  end

  def list_models
    models = @client.models['models']
    models.map { |model| model['name'].delete_prefix('models/') }
  end
end
