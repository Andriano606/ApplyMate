# frozen_string_literal: true

class ApplyMate::Scraper::ErrorHandler::Base
  class AttemptsExhaustedError < StandardError; end

  def initialize(max_retries: 3, base_delay: 2)
    @max_retries = max_retries
    @base_delay = base_delay
  end

  def run
    attempts = 0

    begin
      # Виконуємо код, переданий у блок
      yield
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      handle_retry(e, attempts += 1)
      retry
    rescue StandardError => e
      # Якщо це помилка статусу (наприклад, 502), яку ми кинули через raise у блоці
      if retryable_error?(e)
        handle_retry(e, attempts += 1)
        retry
      else
        # Непередбачувана помилка — прокидаємо далі негайно
        raise e
      end
    end
  end

  private

  def retryable_error?(error)
    # Перевіряємо, чи є в повідомленні помилки коди 502, 503 або 504
    error.message.match?(/502|503|504/)
  end

  def handle_retry(error, attempts)
    if attempts > @max_retries
      Rails.logger.error "[Scraper] Спроби вичерпано для: #{error.message}"
      raise AttemptsExhaustedError, "Final failure after #{@max_retries} retries. Last error: #{error.message}"
    end

    wait_time = @base_delay * (2**attempts)
    Rails.logger.warn "[Scraper] Помилка: #{error.class} (#{error.message}). Спроба #{attempts}. Чекаємо #{wait_time}с..."
    sleep(wait_time)
  end
end
