# frozen_string_literal: true

class ApplyMate::Client::Http < ApplyMate::Client::Base
  def initialize(timeout: 15)
    @timeout = timeout
    @connection = Faraday.new do |f|
      f.use Faraday::FollowRedirects::Middleware
      f.options.timeout = timeout
      f.options.open_timeout = timeout
      f.headers['User-Agent'] = USER_AGENT
      f.adapter Faraday.default_adapter
    end
  end

  def get(url, headers: {}, follow_redirects: false, error_handler: default_error_handler)
    error_handler.run do
      response = @connection.get(url, nil, headers)
      final_url = response.env.url.to_s

      if !follow_redirects && final_url != url
        Rails.logger.info "[ApplyMate::Client::Http] redirecting to an unexpected page: #{url}, #{final_url}"
        next Response.new(nil, response.headers, response.status)
      end

      if response.success?
        Response.new(response.body, response.headers, response.status)
      else
        raise "[ApplyMate::Client::Http] Помилка запиту: #{response.status}"
      end
    end
  end

  def post(url, body:, headers: {}, error_handler: default_error_handler)
    error_handler.run do
      response = @connection.post(url, body, headers)
      if response.success?
        Response.new(response.body, response.headers, response.status)
      else
        raise "[ApplyMate::Client::Http] POST error: #{response.status}"
      end
    end
  end

  def fetch_body(url, error_handler: default_error_handler)
    get(url, error_handler: error_handler)&.body
  end

  def post_xhr(url, body, headers = {}, error_handler: default_error_handler)
    post(url, body: body, headers: headers, error_handler: error_handler)&.body
  end

  # Sends a multipart POST without following redirects, so the caller can
  # inspect 3xx responses directly (e.g. to detect a successful form submission).
  def post_multipart(url, payload:, headers: {})
    connection = Faraday.new do |f|
      f.request :multipart
      f.request :url_encoded
      f.options.timeout      = @timeout
      f.options.open_timeout = @timeout
      headers.each { |k, v| f.headers[k] = v }
      f.headers['User-Agent'] = USER_AGENT
      f.adapter Faraday.default_adapter
    end

    response = connection.post(url, payload)
    Response.new(response.body, response.headers, response.status)
  end

  private

  def default_error_handler
    ApplyMate::Client::ErrorHandler.new(max_retries: 5, base_delay: 1)
  end
end
