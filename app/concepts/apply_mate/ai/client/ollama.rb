# frozen_string_literal: true

class ApplyMate::Ai::Client::Ollama < ApplyMate::Ai::Client::Base
  TAGS_PATH = '/api/tags'

  def initialize(host:, model: nil, **)
    @host = host.to_s.chomp('/')
    @model = model
  end

  def ask(text)
    client = ::Ollama.new(
      credentials: { address: @host },
      options: { model: @model, server_sent_events: true }
    )
    events = client.chat({
      model: @model,
      messages: [ { role: 'user', content: text } ]
    })
    events.filter_map { |e| e.dig('message', 'content') }.join
  rescue StandardError => e
    Rails.logger.error "Ollama API failure: #{e.message}"
    raise e
  end

  def list_models
    response = Faraday.get("#{@host}#{TAGS_PATH}")
    return [] unless response.success?
    JSON.parse(response.body)['models']&.map { |m| m['name'] } || []
  rescue StandardError => e
    Rails.logger.error "Ollama list_models failure: #{e.message}"
    []
  end
end
