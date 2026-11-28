# frozen_string_literal: true

class ApplyMate::Scraper::Base
  include ApplyMate::Logging

  # Raised when the proxy behind the HTTP client is unusable. The sync pipeline rescues
  # this to drop the proxy from the run's pool and retry the same work on another IP. The
  # message is a short reason ("HTTP 403 Cloudflare", "empty job list (proxy rate-limited)",
  # curl's error text).
  DeadProxyError = Class.new(StandardError)

  # Statuses that mean "this IP can't be used right now": rate-limited, or a gateway the
  # proxy could not get through. A Cloudflare block/challenge page means the same at any
  # status (see #via_proxy).
  PROXY_DEAD_STATUSES = [ 429, 502, 503, 504 ].freeze

  # Tags that carry no readable content (or execute code) — dropped from the
  # description HTML before it is stored. Everything else is kept verbatim so the
  # vacancy page can render the source's own paragraphs, lists and emphasis.
  NON_CONTENT_TAGS = %w[script style noscript iframe object embed link meta form].freeze

  # Attributes dropped alongside them: `on*` handlers execute, the rest are presentation
  # and tracking that no renderer of ours ever reads. `id` is kept — in-page anchors
  # inside a description depend on it.
  NON_CONTENT_ATTRIBUTE_PREFIXES = %w[on data-].freeze
  NON_CONTENT_ATTRIBUTES         = %w[class style].freeze

  # HTTP client the sync pipeline builds for this source: curl-impersonate, the tool
  # ProxyMate checks proxies with (ApplyMate::Client::ImpersonateHttp). A client class takes
  # the (proxy:, request_timeout:, connect_timeout:, clearance:) constructor and answers the
  # `supported_proxy_protocols` / `supports_cloudflare_clearance?` predicates the sync pool
  # turns into its ProxyMate request.
  def self.http_client_class
    ApplyMate::Client::ImpersonateHttp
  end

  # ProxyMate site slug (GET /api/v1/sites) whose checked proxies the sync pool asks for —
  # ProxyMate checks every proxy on every site separately, so the slug picks the right list.
  def self.proxy_site
    raise NotImplementedError, "#{name} must declare its ProxyMate site (self.proxy_site)"
  end

  # Public URL of the source's vacancy listing — the page a person opens to browse
  # its jobs. Override with the real listing endpoint; the default is the homepage.
  # Used by the totals widget (each per-source pill links here).
  def self.listing_url(source)
    source.base_url.to_s
  end

  # Does this source fetch the full description from a per-vacancy detail page in the
  # second pass (true), or does the listing already carry the final description (false)?
  # When true, the listing must NOT write/overwrite `description` — the detail pass owns
  # it — and the detail pass only runs for vacancies that don't have one yet.
  def self.fetches_description?
    false
  end

  # Plain-text projection of a description's HTML. `description_html` is what the
  # vacancy page renders; this is what Elasticsearch indexes and what the card
  # preview truncates — so it must be derived here, in one
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

  private

  # Runs an HTTP client call made under proxy rotation and turns every proxy-level
  # failure into DeadProxyError so the sync pipeline drops the proxy and retries on
  # another IP: a transport error (curl failed — refused, timeout, tunnel, TLS…), a
  # PROXY_DEAD_STATUSES reply, or a Cloudflare block/challenge page. Without this, a
  # failed request would look like an empty page and the pipeline would mistake it for
  # the end of the listing. A curl binary that cannot start is the host's fault, not the
  # proxy's — it is let through so it never burns the pool.
  def via_proxy
    response =
      begin
        yield
      rescue ApplyMate::Client::ImpersonateHttp::BinaryError
        raise
      rescue StandardError => e
        raise DeadProxyError, "transport failure (#{e.class}: #{e.message})"
      end

    status     = response.status
    cloudflare = status != 200 && cloudflare_page?(response.body.to_s)
    raise DeadProxyError, "HTTP #{status}#{' Cloudflare' if cloudflare}" if cloudflare || PROXY_DEAD_STATUSES.include?(status)

    response
  end

  # A Cloudflare block ("Attention Required! | Cloudflare", "Access denied") or challenge
  # ("Just a moment…") page.
  def cloudflare_page?(body)
    body.include?('<title>Just a moment') || body.include?('_cf_chl_opt') || body.include?('cf-chl') ||
      body.match?(%r{<title>\s*(Attention Required! \| Cloudflare|Access denied)}i)
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
