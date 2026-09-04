# frozen_string_literal: true

class ApplyMate::Scraper::Base
  include ApplyMate::Logging

  # Raised when the proxy behind the HTTP client is unusable. The sync pipeline
  # rescues this to drop the proxy and retry the same work on another IP.
  class DeadProxyError < StandardError; end

  # Upstream/proxy statuses that mean "this IP can't be used right now".
  PROXY_DEAD_STATUSES = [ 502, 503, 504 ].freeze

  # Tags that carry no readable content (or execute code) — dropped from the
  # description HTML before it is stored. Everything else is kept verbatim so the
  # vacancy page can render the source's own paragraphs, lists and emphasis.
  NON_CONTENT_TAGS = %w[script style noscript iframe object embed link meta form].freeze

  # Attributes dropped alongside them: `on*` handlers execute, the rest are presentation
  # and tracking that no renderer of ours ever reads. `id` is kept — in-page anchors
  # inside a description depend on it.
  NON_CONTENT_ATTRIBUTE_PREFIXES = %w[on data-].freeze
  NON_CONTENT_ATTRIBUTES         = %w[class style].freeze

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

  # Plain-text projection of a description's HTML. `description_html` is what the
  # vacancy page renders; this is what Elasticsearch indexes, what the AI prompts
  # embed and what the card preview truncates — so it must be derived here, in one
  # place, instead of each caller re-inventing its own tag stripping.
  def self.to_plain_text(html)
    return '' if html.blank?

    Html2Text.convert(html)
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

  # Inner HTML of a scraped description node, kept as-is apart from non-content tags
  # and non-content attributes. Structure and emphasis survive on purpose — stripping
  # them here is what used to flatten every vacancy into one wall of text. Rendering
  # re-sanitises against a tag allow-list (Component::RichText).
  def content_html(node)
    return '' if node.nil?

    fragment = Nokogiri::HTML::DocumentFragment.parse(node.inner_html)
    fragment.css(NON_CONTENT_TAGS.join(',')).each(&:remove)
    fragment.css('*').each { |element| strip_non_content_attributes(element) }

    fragment.to_html.strip
  end

  # A source's own `class`/`style`/`data-*` never reach the page (RichText's attribute
  # allow-list drops them) but would still be stored on every one of ~1M rows — Dou and
  # Djinni markup is mostly attribute by weight. Dropped as a blocklist, not as a copy
  # of RichText's allow-list, so the two can't drift into disagreeing.
  def strip_non_content_attributes(element)
    element.attribute_nodes.each do |attribute|
      name = attribute.name.downcase
      next unless name.start_with?(*NON_CONTENT_ATTRIBUTE_PREFIXES) || NON_CONTENT_ATTRIBUTES.include?(name)

      element.remove_attribute(attribute.name)
    end
  end
end
