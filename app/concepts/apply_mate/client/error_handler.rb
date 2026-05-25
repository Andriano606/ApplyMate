# frozen_string_literal: true

# Wraps a single HTTP call: classifies failures, retries with exponential
# backoff, raises AttemptsExhaustedError when the budget runs out. Pass an
# instance to the client constructor — the client calls `run { … }` around
# each request, so all retry/error policy lives here.
class ApplyMate::Client::ErrorHandler
  class AttemptsExhaustedError < StandardError; end

  # Transport-level errors worth retrying.
  RETRYABLE_EXCEPTIONS = [
    Errno::ECONNREFUSED,
    Errno::ECONNRESET,
    Errno::ETIMEDOUT,
    IO::TimeoutError,
    EOFError,
    ApplyMate::Client::Base::RetryableHttpError
  ].freeze

  # HTTP statuses that should trigger a retry (server-side transient failures).
  RETRYABLE_STATUSES = [ 502, 503, 504 ].freeze

  def initialize(max_retries: 3, base_delay: 2)
    @max_retries = max_retries
    @base_delay  = base_delay
  end

  def run
    attempts = 0
    begin
      response = yield
      check_retryable_status(response)
      response
    rescue *RETRYABLE_EXCEPTIONS => e
      handle_retry(e, attempts += 1)
      retry
    end
  end

  private

  def check_retryable_status(response)
    return unless response.is_a?(ApplyMate::Client::Base::Response)
    return unless RETRYABLE_STATUSES.include?(response.status)

    raise ApplyMate::Client::Base::RetryableHttpError, "HTTP #{response.status}"
  end

  def handle_retry(error, attempts)
    if attempts > @max_retries
      raise AttemptsExhaustedError, "Final failure after #{@max_retries} retries. Last error: #{error.message}"
    end

    wait_time = @base_delay * (2**attempts)
    sleep(wait_time)
  end
end
