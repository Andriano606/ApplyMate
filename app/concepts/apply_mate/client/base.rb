# frozen_string_literal: true

class ApplyMate::Client::Base
  Response = Struct.new(:body, :headers, :status) do
    def success?
      (200..299).include?(status)
    end
  end

  class DeadProxyError < StandardError; end

  USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

  def fetch_body(url)
    raise NotImplementedError
  end
end
