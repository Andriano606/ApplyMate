# frozen_string_literal: true

class ApplyMate::Ai::Client::Ollama < ApplyMate::Ai::Client::Base
  TAGS_PATH = '/api/tags'
  # Context window requested per call. Prompts carry a page snapshot's element lines
  # (Navigate, RecoverField) or the full CV and vacancy text (GenerateCv, AnswerFields);
  # Ollama's server-side default context is far smaller and silently truncates the prompt
  # head instead of failing.
  NUM_CTX = 16_384

  # Vision depends on the pulled model (llava, gemma3, …), so it is not declared in phase 0.
  def self.capabilities
    %i[json_schema].freeze
  end

  def initialize(host:, model: nil, **)
    @host = host.to_s.chomp('/')
    @model = model
  end

  def complete(request)
    assert_request!(request)
    client = ::Ollama.new(
      credentials: { address: @host },
      options: { server_sent_events: false, connection: { request: { timeout: request.timeout } } }
    )
    parse(client.chat(payload_for(request)))
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

  private

  def payload_for(request)
    messages = request.messages.map { |message| message_for(message) }
    messages.unshift({ role: 'system', content: request.system }) if request.system.present?
    payload = {
      model:    @model,
      stream:   false,
      messages:,
      # Thinking models spend their reasoning from num_predict too, so the cap includes it.
      options:  { num_ctx: NUM_CTX, num_predict: request.output_token_limit }
    }
    payload[:format] = request.json_schema if request.json_schema
    payload
  end

  def message_for(message)
    { role: message[:role].to_s == 'model' ? 'assistant' : 'user', content: message[:content] }
  end

  # ollama-ai 1.3.0 without SSE parses the body as JSON Lines and returns an Array; with
  # `stream: false` the server sends exactly one line. A non-JSON body comes back as a String.
  def parse(result)
    raise "Ollama returned a non-JSON body: #{result.to_s.truncate(200)}" unless result.is_a?(Array)

    event = result.sole
    text = event.dig('message', 'content')
    if text.nil?
      raise ApplyMate::Ai::Client::Base::EmptyResponse,
            "Ollama returned no message content (done_reason: #{event['done_reason'].inspect})"
    end

    usage = ApplyMate::Ai::Usage.new(input_tokens: event['prompt_eval_count'], output_tokens: event['eval_count'])
    ApplyMate::Ai::Response.new(text:, usage:)
  end
end
