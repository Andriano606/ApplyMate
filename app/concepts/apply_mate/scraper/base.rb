# frozen_string_literal: true

class ApplyMate::Scraper::Base
  include ApplyMate::Logging

  # Raised when the proxy behind the HTTP client is unusable. The sync pipeline
  # rescues this to drop the proxy and retry the same work on another IP.
  class DeadProxyError < StandardError; end

  # Upstream/proxy statuses that mean "this IP can't be used right now".
  PROXY_DEAD_STATUSES = [ 502, 503, 504 ].freeze

  def fetch_listing(page:)
    raise NotImplementedError
  end

  def fetch_description(url)
    raise NotImplementedError
  end

  def fetch_details(url)
    raise NotImplementedError
  end

  def fetch_applyble(url, session_id:)
    raise NotImplementedError
  end

  def fetch_apply_type(url, session_id:)
    raise NotImplementedError
  end

  def form_selector
    raise NotImplementedError
  end

  private

  # Runs an HTTP client call made under proxy rotation and normalises every
  # failure into DeadProxyError so the sync pipeline drops the proxy and retries
  # on another IP. The client itself raises raw transport errors (Errno::*,
  # SSLError, Async::TimeoutError, …) and returns nil / a 5xx Response for an
  # unusable reply — all of which mean this proxy can't be used here. Without
  # this, a failed request would look like an empty page and the pipeline would
  # mistake it for the end of the listing.
  def via_proxy
    response =
      begin
        yield
      rescue StandardError => e
        raise DeadProxyError, "transport failure (#{e.class}: #{e.message})"
      end

    raise DeadProxyError, 'no response (proxy failed)' if response.nil?
    raise DeadProxyError, "HTTP #{response.status} (proxy failed)" if PROXY_DEAD_STATUSES.include?(response.status)

    response
  end

  def full_url(path)
    return nil if path.blank?
    URI.join(@source.base_url, path).to_s
  rescue StandardError
    path
  end

  def sanitize_html(html, compact: false)
    return '' if html.blank?
    text = Html2Text.convert(html)
    return text unless compact
    text.gsub(/[\t\r\n]+/, ' ').gsub(/\s{2,}/, ' ').strip
  end
end
