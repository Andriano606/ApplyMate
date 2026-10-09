# frozen_string_literal: true

class ApplyMate::Ai::Client::Gemini < ApplyMate::Ai::Client::Base
  MODELS_ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/models'
  CREDENTIALS_SERVICE = 'generative-language-api'
  # The gemini-ai gem defaults to v1, which refuses JSON mode (response_mime_type / response_schema) with a 400
  # "JSON mode is not enabled for api version v1"; every engine schema (Navigate, AnswerFields, VerifySubmit, ...)
  # is native JSON schema, so the client talks v1beta like MODELS_ENDPOINT.
  API_VERSION = 'v1beta'
  # Transient upstream failures worth retrying (at most Request#retries times, sleeping 2 s then 4 s).
  RETRYABLE_ERROR = /503|502|429|high demand|overloaded|RESOURCE_EXHAUSTED|UNAVAILABLE/
  # A quota that will not come back within a run: the error body names a per-day quota
  # (QuotaFailure quotaId "GenerateRequestsPerDayPerProjectPerModel-FreeTier") or asks to wait at least
  # QUOTA_RETRY_DELAY seconds (RetryInfo retryDelay "67247s"). A per-minute rate limit is neither: it stays Unavailable.
  QUOTA_PER_DAY = /PerDay|per[ _-]day|daily/i
  RETRY_DELAY = /"retryDelay"\s*:\s*"(\d+)(?:\.\d+)?s"/
  QUOTA_RETRY_DELAY = 3_600
  # Provider errors retried as transient (5xx include the gem's wrapped ones, see #faraday_error) and raised as Unavailable.
  TRANSIENT_ERRORS = [ Faraday::TooManyRequestsError, Faraday::ServerError, Faraday::TimeoutError, Faraday::ConnectionFailed ].freeze
  # Characters of message + error body kept in a ProviderError's message.
  ERROR_TEXT_LIMIT = 600
  # JSON-Schema keys the Gemini `responseSchema` (OpenAPI subset) understands; everything else
  # (additionalProperties, $schema, minimum, …) is dropped because the API rejects unknown fields.
  SCHEMA_KEYS = %w[type nullable properties required items enum maxItems minItems description].freeze
  # Models that accept generation_config.thinking_config: Gemini 2.5 and later text models
  # (pro / flash / flash-lite, incl. dated previews). Older models (2.0, 1.5) and image/tts
  # variants reject the field with a 400, so they only get the raised output cap.
  THINKING_MODEL = /\Agemini-(?:2\.5|[3-9](?:\.\d+)?)-(?:pro|flash)(?:-lite)?(?:-preview[-\w]*)?\z/

  def self.capabilities
    %i[json_schema vision].freeze
  end

  def self.validate_api_key!(api_key:)
    # Header, not ?key=: a Faraday error raised here would otherwise carry the key in its URL.
    response = Faraday.get(MODELS_ENDPOINT, nil, { 'x-goog-api-key' => api_key })
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
    result = with_retries(request.retries) { client.generate_content(payload) }
    parse(result)
  end

  def list_models
    models = with_retries(0) { @client.models['models'] }
    models.map { |model| model['name'].delete_prefix('models/') }
  end

  private

  def build_client(timeout: nil)
    options = { model: @model, server_sent_events: false }
    options[:connection] = { request: { timeout: } } if timeout
    ::Gemini.new(credentials: { service: CREDENTIALS_SERVICE, api_key: @api_key, version: API_VERSION }, options:)
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
  # `type: 'STRING', nullable: true`, recursion into properties/items, unknown keys dropped. A nullable enum lists
  # null in JSON Schema (`enum: [..., nil]`); Gemini's enum holds strings only, so null leaves the list and the field
  # is nullable instead.
  def gemini_schema(schema)
    schema = schema.deep_stringify_keys
    converted = schema.slice(*SCHEMA_KEYS)
    converted.merge!(gemini_type(schema['type'])) if schema.key?('type')
    if schema['enum']
      converted['enum'] = schema['enum'].compact.map(&:to_s)
      converted['nullable'] = true if schema['enum'].include?(nil)
    end
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

  # Every failure leaves as a ProviderError subclass with a scrubbed message and no cause (see Base::ProviderError):
  # a long quota -> QuotaExhausted at once, a transient one -> retried up to `max_retries` times then Unavailable,
  # anything else -> ProviderError.
  def with_retries(max_retries)
    retries = 0
    begin
      yield
    rescue StandardError => e
      source = faraday_error(e)
      text = "#{e.message} #{response_body(source)}"
      quota = (source.is_a?(Faraday::TooManyRequestsError) || text.include?('RESOURCE_EXHAUSTED')) && long_quota?(text)
      transient = !quota && (TRANSIENT_ERRORS.any? { |klass| source.is_a?(klass) } || e.message.match?(RETRYABLE_ERROR))
      if retries < max_retries && transient
        retries += 1
        sleep(2**retries)
        retry
      end
      raise provider_error(e, text, quota:, transient:), cause: nil
    end
  end

  # "<class>: <message> <body excerpt>", scrubbed: the body says which quota or limit was hit.
  def provider_error(error, text, quota:, transient:)
    message = "#{error.class}: #{ApplyMate::Ai::Client::Base.scrub(text).squish.truncate(ERROR_TEXT_LIMIT)}"
    Rails.logger.error "Gemini API failure: #{message}"
    error_class(quota:, transient:).new(message)
  end

  def error_class(quota:, transient:)
    return ApplyMate::Ai::Client::Base::QuotaExhausted if quota
    return ApplyMate::Ai::Client::Base::Unavailable if transient

    ApplyMate::Ai::Client::Base::ProviderError
  end

  def long_quota?(text)
    text.match?(QUOTA_PER_DAY) || text[RETRY_DELAY, 1].to_i >= QUOTA_RETRY_DELAY
  end

  # The Faraday error behind `error`: the gemini-ai gem wraps a 5xx in a Gemini::Errors::RequestError whose `request`
  # is the Faraday error; anything else is its own source.
  def faraday_error(error)
    error.respond_to?(:request) && error.request.is_a?(Faraday::Error) ? error.request : error
  end

  # The provider's error body (Faraday keeps it on the error), '' when there is none.
  def response_body(source)
    body = source.respond_to?(:response_body) ? source.response_body : nil
    body.is_a?(String) || body.nil? ? body.to_s : body.to_json
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
