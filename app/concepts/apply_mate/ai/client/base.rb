# frozen_string_literal: true

class ApplyMate::Ai::Client::Base
  # Raised when a request needs something the client cannot do (e.g. images on a client
  # without :vision).
  class CapabilityMissing < StandardError; end

  # Raised when the provider answered but produced no text: a safety block or a MAX_TOKENS
  # cut-off. Distinct from a blank/unparseable answer (ResponseSchema::Json::InvalidResponse)
  # so callers can tell "the model said nothing" from "the model said something unusable".
  class EmptyResponse < StandardError; end

  # Raised when Request#timeout is shorter than the client can possibly answer in (GeminiScraping: less than its
  # browser SETUP_SECONDS), before any work starts. The apply Runner maps it to Halt(:deadline): the run is out of
  # time, nothing is contended. (A taken local Chrome slot is ApplyMate::Client::LocalChrome::Busy.)
  class DeadlineTooShort < StandardError; end

  # A provider failure an API client gives up on (Gemini: every transport / HTTP error out of `complete` and
  # `list_models`; Ollama is local and keyless and raises its own). The message is "<original class>: <scrubbed message>" (Base.scrub) and
  # the error is raised with `cause: nil`, so neither the message nor the cause chain (Rails.error.report, logs, the
  # engine's failure detail) carries the request URL; Gemini's has the API key in its query string.
  class ProviderError < StandardError; end

  # The provider is overloaded or rate-limits the caller (HTTP 429 / 502 / 503 / timeouts) after the retries the caller
  # allowed (Request#retries; Apply::Operation::Engine::CallAi owns the engine's own bounded retry). The apply Runner
  # maps it to the transient Halt(:capacity): nothing about the application is wrong, a later attempt may succeed.
  class Unavailable < ProviderError; end

  # The provider says the integration's quota is used up for a long period (Gemini: a per-day quota, or a retryDelay
  # of an hour or more). Never retried: the apply Runner maps it to Halt(:ai_quota_exhausted) (needs_human: retry later
  # or pick another integration), not to :capacity, whose one auto-resume would fail the same way.
  class QuotaExhausted < ProviderError; end

  # Credentials in an error message or URL: query/form parameters (`?key=AIza...`, `&api_key=`, `apikey=`,
  # `access_token=`, `id_token=`, `X-Amz-Signature=`, `sig=`) and bare Google API keys (`AIza` + 35 characters).
  SECRET_PARAM = /(\b(?:api_?key|key|signature|sig)|token)=[^&?\s"'#;,]+/i
  GOOGLE_API_KEY = /AIza[0-9A-Za-z_-]{35}/

  # The text with every credential masked; the ONE credential scrubber (client logs and ProviderError messages here,
  # everything the apply engine stores via Apply::Operation::Engine::Redact, which calls it).
  def self.scrub(text)
    text.to_s.gsub(SECRET_PARAM, '\\1=[REDACTED]').gsub(GOOGLE_API_KEY, '[REDACTED]')
  end

  # What the client can do natively. Allowed symbols:
  #   :json_schema    — sends ApplyMate::Ai::Request#json_schema as a native structured-output constraint
  #   :vision         — accepts ApplyMate::Ai::Request#images
  #   :browser_backed — drives a real browser (GeminiScraping); occupies a browser slot on the host
  def self.capabilities
    [].freeze
  end

  def self.supports?(capability)
    capabilities.include?(capability)
  end

  # The client's declared latency: worst-case seconds one call of `kind` takes (an HTTP API: the kind's
  # ApplyMate::Ai::Request::TIMEOUTS; GeminiScraping: CALL_SECONDS). AiHandler gives a request this timeout when the caller
  # sets none, and Apply::Operation::Engine::CallAi sizes the engine's budgets (Navigator, field recovery, scope and run
  # deadlines, browserd lease TTL) from it.
  def self.call_seconds(kind)
    ApplyMate::Ai::Request::TIMEOUTS.fetch(kind)
  end

  def self.validate_api_key!(api_key:)
    raise NotImplementedError
  end

  # ApplyMate::Ai::Request → ApplyMate::Ai::Response
  def complete(request)
    raise NotImplementedError
  end

  def list_models
    raise NotImplementedError
  end

  protected

  # A json_schema on a client without :json_schema is not an error: the schema is simply not
  # sent natively and the format_instructions text still steers the model. Images are — a
  # text-only client would silently drop the evidence the caller relies on.
  def assert_request!(request)
    return unless request.images.any? && !self.class.supports?(:vision)

    raise CapabilityMissing, "#{self.class.name} lacks vision; the request carries #{request.images.size} image(s)"
  end
end
