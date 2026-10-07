# frozen_string_literal: true

class ApplyMate::Ai::Client::Gemini < ApplyMate::Ai::Client::Base
  MODELS_ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/models'
  CREDENTIALS_SERVICE = 'generative-language-api'
  # Transient upstream failures worth retrying: 2 retries, sleeping 2 s then 4 s.
  RETRYABLE_ERROR = /503|502|429/
  MAX_RETRIES = 2
  # JSON-Schema keys the Gemini `responseSchema` (OpenAPI subset) understands; everything else
  # (additionalProperties, $schema, …) is dropped because the API rejects unknown fields.
  SCHEMA_KEYS = %w[type nullable properties required items enum description].freeze
  # Models that accept generation_config.thinking_config: Gemini 2.5 and later text models
  # (pro / flash / flash-lite, incl. dated previews). Older models (2.0, 1.5) and image/tts
  # variants reject the field with a 400, so they only get the raised output cap.
  THINKING_MODEL = /\Agemini-(?:2\.5|[3-9](?:\.\d+)?)-(?:pro|flash)(?:-lite)?(?:-preview[-\w]*)?\z/

  def self.capabilities
    %i[json_schema vision].freeze
  end

  def self.validate_api_key!(api_key:)
    response = Faraday.get(MODELS_ENDPOINT, { key: api_key })
    raise 'invalid_api_key' unless response.success?
  end

  def initialize(api_key:, model: 'gemini-2.5-flash', **)
    @api_key = api_key
    @model = model
    # Constructor-built client serves list_models only; `complete` builds one per request
    # because the HTTP timeout is per request kind.
    @client = build_client
  end

  def complete(request)
    assert_request!(request)
    client = build_client(timeout: request.timeout)
    payload = payload_for(request)
    result = with_retries { client.generate_content(payload) }
    parse(result)
  end

  def list_models
    models = @client.models['models']
    models.map { |model| model['name'].delete_prefix('models/') }
  end

  private

  def build_client(timeout: nil)
    options = { model: @model, server_sent_events: false }
    options[:connection] = { request: { timeout: } } if timeout
    ::Gemini.new(credentials: { service: CREDENTIALS_SERVICE, api_key: @api_key }, options:)
  end

  def payload_for(request)
    payload = { contents: request.messages.map { |message| content_for(message) } }
    append_images(payload[:contents], request.images)
    payload[:system_instruction] = { parts: [ { text: request.system } ] } if request.system.present?
    payload[:generation_config] = generation_config_for(request)
    payload
  end

  def content_for(message)
    role = message[:role].to_s == 'model' ? 'model' : 'user'
    { role:, parts: [ { text: message[:content] } ] }
  end

  # Images ride on the last user turn, after its text part.
  def append_images(contents, images)
    return if images.empty?

    target = contents.reverse.find { |content| content[:role] == 'user' }
    images.each { |image| target[:parts] << { inline_data: { mime_type: image[:mime_type], data: image[:data] } } }
  end

  # Thinking tokens count against max_output_tokens, so the cap is answer + thinking budget and
  # thinking itself is bounded; otherwise dynamic thinking can eat the whole cap and return no text.
  def generation_config_for(request)
    config = { max_output_tokens: request.output_token_limit }
    config[:thinking_config] = { thinking_budget: request.thinking_budget } if THINKING_MODEL.match?(@model.to_s)
    return config unless request.json_schema

    config.merge(response_mime_type: 'application/json', response_schema: gemini_schema(request.json_schema))
  end

  # JSON-Schema subset → Gemini responseSchema: `type` upcased, `['string', 'null']` →
  # `type: 'STRING', nullable: true`, recursion into properties/items, unknown keys dropped.
  def gemini_schema(schema)
    schema = schema.deep_stringify_keys
    converted = schema.slice(*SCHEMA_KEYS)
    converted.merge!(gemini_type(schema['type'])) if schema.key?('type')
    converted['properties'] = schema['properties'].transform_values { |prop| gemini_schema(prop) } if schema['properties']
    converted['items'] = gemini_schema(schema['items']) if schema['items']
    converted
  end

  def gemini_type(type)
    types = Array(type).map(&:to_s)
    concrete = types - [ 'null' ]
    raise ArgumentError, "Gemini responseSchema supports one non-null type, got #{types.inspect}" unless concrete.one?

    result = { 'type' => concrete.first.upcase }
    result['nullable'] = true if types.include?('null')
    result
  end

  def with_retries
    retries = 0
    begin
      yield
    rescue StandardError => e
      if retries < MAX_RETRIES && e.message.match?(RETRYABLE_ERROR)
        retries += 1
        sleep(2**retries)
        retry
      end
      Rails.logger.error "Gemini API failure: #{e.message}"
      raise e
    end
  end

  def parse(result)
    result = {} unless result.is_a?(Hash)
    text = result.dig('candidates', 0, 'content', 'parts', 0, 'text')
    raise ApplyMate::Ai::Client::Base::EmptyResponse, no_text_error(result) if text.nil?

    ApplyMate::Ai::Response.new(text:, usage: usage_from(result['usageMetadata']))
  end

  # Safety blocks and MAX_TOKENS cut-offs come back without text. Raising EmptyResponse (instead
  # of returning nil) keeps them out of the schemas' blank-response paths and keeps the diagnostics.
  def no_text_error(result)
    finish_reason = result.dig('candidates', 0, 'finishReason')
    block_reason = result.dig('promptFeedback', 'blockReason')
    thoughts = result.dig('usageMetadata', 'thoughtsTokenCount')
    "Gemini returned no text (finishReason: #{finish_reason.inspect}, blockReason: #{block_reason.inspect}, " \
      "thoughtsTokenCount: #{thoughts.inspect})"
  end

  # Thinking tokens (thoughtsTokenCount) are billed as output, so they are counted as output here.
  def usage_from(metadata)
    return ApplyMate::Ai::Usage::UNKNOWN unless metadata.is_a?(Hash)

    candidates = metadata['candidatesTokenCount']
    thoughts = metadata['thoughtsTokenCount']
    output = (candidates || thoughts) ? candidates.to_i + thoughts.to_i : nil
    ApplyMate::Ai::Usage.new(input_tokens: metadata['promptTokenCount'], output_tokens: output)
  end
end
