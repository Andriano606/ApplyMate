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
