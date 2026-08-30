# frozen_string_literal: true

class ApplyMate::Scraper::Base
  include ApplyMate::Logging

  # Raised when the proxy behind the HTTP client is unusable. The sync pipeline
  # rescues this to drop the proxy and retry the same work on another IP.
  class DeadProxyError < StandardError; end

  # Upstream/proxy statuses that mean "this IP can't be used right now".
  PROXY_DEAD_STATUSES = [ 502, 503, 504 ].freeze

  # HTTP client the sync pipeline builds for this source. Default is the fast
  # pure-Ruby AsyncHttp; Cloudflare-protected sources override this to a client
  # that passes the TLS-fingerprint check (see ApplyMate::Client::ImpersonateHttp).
  # Both share the (proxy:, request_timeout:, connect_timeout:) constructor.
  def self.http_client_class
    ApplyMate::Client::AsyncHttp
  end

  # URL the proxy validator (and the sync pool's live re-check) probes to decide a
  # proxy is usable for this source. Override to the real listing endpoint so that
  # "working" means the proxy actually reaches the page we scrape, not just the
  # (less-protected) homepage.
  def self.validation_url(source)
    source.base_url.to_s
  end

  # Does this source fetch the full description from a per-vacancy detail page in the
  # second pass (true), or does the listing already carry the final description (false)?
  # When true, the listing must NOT write/overwrite `description` — the detail pass owns
  # it — and the detail pass only runs for vacancies that don't have one yet.
  def self.fetches_description?
    false
  end

  # Seconds a proxy rests after a burst of requests to this source (sync ProxyPool).
  # Override per source: Cloudflare-protected sites are rate-sensitive (a short cooldown
  # triggers more blocks → proxy churn → slower), CF-free sites just want throughput.
  def self.burst_cooldown
    5
  end

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
