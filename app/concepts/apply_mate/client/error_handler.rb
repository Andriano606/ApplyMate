# frozen_string_literal: true

class ApplyMate::Client::ErrorHandler
  class AttemptsExhaustedError < StandardError; end

  def initialize(max_retries: 3, base_delay: 2)
    @max_retries = max_retries
    @base_delay  = base_delay
  end

  def run
    attempts = 0

    begin
      yield
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      handle_retry(e, attempts += 1)
      retry
    rescue StandardError => e
      if retryable_error?(e)
        handle_retry(e, attempts += 1)
        retry
      else
        raise e
      end
    end
  end

  private

  def retryable_error?(error)
    error.message.match?(/502|503|504/)
  end

  def handle_retry(error, attempts)
    if attempts > @max_retries
      Rails.logger.error "[Client] Спроби вичерпано: #{error.message}"
      raise AttemptsExhaustedError, "Final failure after #{@max_retries} retries. Last error: #{error.message}"
    end

    wait_time = @base_delay * (2**attempts)
    Rails.logger.warn "[Client] #{error.class} (#{error.message}). Спроба #{attempts}, чекаємо #{wait_time}с..."
    sleep(wait_time)
  end
end
