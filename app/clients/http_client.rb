# frozen_string_literal: true

# c = HttpClient.new
# r = c.fetch_body('https://djinni.co/jobs/')

class HttpClient < BaseClient
  def initialize(timeout: 15)
    @connection = Faraday.new do |f|
      # Дозволяє автоматично переходити за редиректами
      f.use Faraday::FollowRedirects::Middleware

      # Налаштування таймаутів, щоб запит не "зависав"
      f.options.timeout = timeout
      f.options.open_timeout = timeout

      # Додаємо стандартний User-Agent, щоб сайт не блокував запит як бот
      f.headers['User-Agent'] = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

      f.adapter Faraday.default_adapter
    end
  end

  def fetch_body(url, error_handler: ScraperErrorHandler.new(max_retries: 5, base_delay: 1))
    error_handler.run do
      response = @connection.get(url)
      final_url = response.env.url.to_s

      if final_url != url
        Rails.logger.info "[HttpClient] redirecting to an unexpected page: #{url}, #{final_url}"
        return nil
      end

      if response.success?
        response.body
      else
        # Викидаємо помилку з кодом статусу, щоб error_handler міг її розпізнати
        raise "[HttpClient] Помилка запиту: #{response.status}"
      end
    end
  end
end
