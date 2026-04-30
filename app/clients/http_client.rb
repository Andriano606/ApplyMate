# frozen_string_literal: true

class HttpClient < BaseClient
  USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

  def initialize(timeout: 15, use_proxy: true, headers: {})
    @timeout   = timeout
    @use_proxy = use_proxy
    @headers   = headers
  end

  def fetch_response(url)
    if @use_proxy
      ProxyPool.with_rotation { |proxy| do_request(url, proxy_url: proxy&.url) }
    else
      do_request(url)
    end
  end

  private

  def do_request(url, proxy_url: nil)
    build_connection(proxy_url:).get(url)
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
    Rails.logger.error "Network error on #{url}: #{e.message}"
    raise
  rescue StandardError => e
    Rails.logger.error "Unexpected error: #{e.message}"
    raise
  end

  def build_connection(proxy_url: nil)
    extra_headers = @headers
    Faraday.new(proxy: proxy_url) do |f|
      f.use Faraday::FollowRedirects::Middleware
      f.ssl[:verify] = false
      f.options.timeout      = @timeout
      f.options.open_timeout = @timeout
      f.ssl[:verify_mode] = OpenSSL::SSL::VERIFY_NONE
      f.headers['User-Agent'] = USER_AGENT
      extra_headers.each { |k, v| f.headers[k] = v }
      f.adapter Faraday.default_adapter
    end
  end
end
