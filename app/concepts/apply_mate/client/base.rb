# frozen_string_literal: true

class ApplyMate::Client::Base
  Response = Struct.new(:body, :headers, :status, :final_url) do
    def success?
      (200..299).include?(status)
    end
  end

  class DeadProxyError     < StandardError; end
  class RetryableHttpError < StandardError; end

  USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

  def self.default_error_handler
    ApplyMate::Client::ErrorHandler.new(max_retries: 5, base_delay: 1)
  end

  def self.merge_default_headers(extra = {})
    extra.each_with_object('User-Agent' => USER_AGENT) { |(k, v), h| h[k.to_s] = v.to_s }
  end
end
