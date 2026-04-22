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

  def fetch_body(url)
    response = @connection.get(url)
    final_url = response.env.url.to_s

    return if final_url != url

    if response.success?
      response.body
    else
      Rails.logger.error "Помилка запиту: #{response.status}"
      raise "Помилка запиту: #{response.status}"
      nil
    end

  rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
    # Ось тут ми перетворюємо помилку сокета на зрозумілу помилку для скрейпера
    Rails.logger.error "Мережева помилка на URL #{url}: #{e.message}"
    raise "Виникла помилка мережі: #{e.message}"
  rescue StandardError => e
    Rails.logger.error "Непередбачувана помилка: #{e.message}"
    raise e
  end
end
