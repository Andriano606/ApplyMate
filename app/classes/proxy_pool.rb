# frozen_string_literal: true

class ProxyPool
  BLOCKED_PATTERNS = [
    /your ip address.*has been blocked/i,
    /ip.*address.*blocked/i,
    /access denied.*ip/i
  ].freeze

  MAX_RETRIES = 20

  def self.next_proxy
    Proxy.available.order(Arel.sql('last_used_at ASC NULLS FIRST')).first
  end

  def self.blocked?(body)
    BLOCKED_PATTERNS.any? { |pattern| pattern.match?(body.to_s) }
  end

  # Generic proxy-rotation wrapper. Yields successive Proxy objects to the block.
  # The block may return a body string or a Faraday response — both are handled for block detection.
  # Falls back to a direct connection (yields nil) when the proxy pool is empty.
  #
  # Usage:
  #   ProxyPool.with_rotation { |proxy| make_request(proxy&.url) }
  def self.with_rotation(max_retries: MAX_RETRIES, &block)
    proxy = next_proxy
    return block.call(nil) unless proxy

    last_error = nil

    max_retries.times do
      proxy ||= next_proxy
      break unless proxy

      proxy.mark_used!

      begin
        result = block.call(proxy)

        body = result.respond_to?(:body) ? result.body : result
        if blocked?(body)
          Rails.logger.warn "[ProxyPool] IP blocked via #{proxy.host}:#{proxy.port}, rotating"
          proxy.mark_failed!
          proxy = next_proxy
          next
        end

        return result
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
        Rails.logger.warn "[ProxyPool] Connection failed via #{proxy.host}:#{proxy.port}: #{e.message}"
        proxy.mark_failed!
        proxy = next_proxy
        last_error = e
      end
    end

    Rails.logger.warn '[ProxyPool] All proxy attempts failed, falling back to direct connection'
    block.call(nil)
  end
end
