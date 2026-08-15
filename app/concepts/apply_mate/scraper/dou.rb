# frozen_string_literal: true

class ApplyMate::Scraper::Dou < ApplyMate::Scraper::Base
  VACANCIES_URL = 'https://jobs.dou.ua/vacancies/'
  XHR_URL       = 'https://jobs.dou.ua/vacancies/xhr-load/'

  # DOU internal apply form — field meanings known from the board's markup.
  ROLE_OVERRIDES = {
    'descr'               => 'cover_letter',
    'user_cv'             => 'cv_file',
    'csrfmiddlewaretoken' => 'hidden_passthrough'
  }.freeze

  # Dou is behind Cloudflare; a Chrome TLS fingerprint (curl-impersonate) passes the
  # challenge that OpenSSL-based AsyncHttp cannot. See .ai/docs/scrapers.md.
  def self.http_client_class
    ApplyMate::Client::ImpersonateHttp
  end

  # The real vacancies listing (not the less-protected homepage) — what the totals
  # widget links to and what proxy validation probes.
  def self.listing_url(_source)
    VACANCIES_URL
  end

  # Dou's full description lives on each vacancy's detail page (fetch_description), so
  # the listing must not write it and the detail pass only runs for missing ones.
  def self.fetches_description?
    true
  end

  # Behind Cloudflare and rate-sensitive — rest a touch longer between bursts.
  def self.burst_cooldown
    5
  end

  def initialize(source, client)
    @source = source
    @client = client
  end

  # Returns the description as HTML, not text: `div.b-typo.vacancy-section` is the
  # employer's own copy (paragraphs, bullet lists, bold headings) and that markup is
  # what the vacancy page renders. Scoped to that section rather than the whole
  # `div.l-vacancy` wrapper, which also holds the share widget, tracking script and
  # reply button — noise once it is rendered as markup instead of flattened text.
  # The `sh-info` line (city / remote / office) is prepended as its own paragraph so
  # it survives the narrower scope.
  # SyncVacancies stores this in `description_html` and derives the plain-text
  # `description` (Elasticsearch, AI prompts, card preview) from it.
  def fetch_description(url)
    response = via_proxy { @client.get(url) }

    html = response.body
    return nil if html.blank?

    doc     = Nokogiri::HTML(html)
    section = doc.at_css('div.b-typo.vacancy-section')
    node    = section || doc.at_css('div.l-vacancy')
    return nil if node.nil?

    # `sh-info` sits outside the section but inside the `l-vacancy` wrapper, so it is
    # prepended only when the narrow scope is what we took — on the fallback path the
    # line is already part of the markup and would otherwise appear twice.
    info = section && doc.at_css('div.sh-info')&.text&.squish
    [ info.presence && "<p>#{ERB::Util.html_escape(info)}</p>", content_html(node) ].compact.join
  end

  def fetch_details(url)
  end

  def form_selector
    'form#replied-id'
  end

  def fetch_applyble(url, session_id:)
    headers = session_id.present? ? { 'Cookie' => "sessionid=#{session_id}" } : {}
    html    = @client.get(url, headers:)&.body
    return false if html.blank?

    doc = Nokogiri::HTML(html)
    doc.at_css('a.replied-external').present? || doc.at_css('a#reply-btn-id').present?
  end

  def fetch_apply_type(url, session_id:)
    headers = session_id.present? ? { 'Cookie' => "sessionid=#{session_id}" } : {}
    html    = @client.get(url, headers:)&.body
    return nil if html.blank?

    doc = Nokogiri::HTML(html)
    if (link = doc.at_css('a.replied-external'))
      { type: 'external', external_url: link['href'] }
    elsif doc.at_css('a#reply-btn-id')
      { type: 'internal', external_url: nil }
    end
  end

  def fetch_listing(page:)
    initialize_session

    count    = (page - 1) * (@items_per_page || 40)
    response = via_proxy { @client.post(XHR_URL, body: URI.encode_www_form(count:), headers: xhr_headers) }
    body     = response.body
    return if body.blank?

    begin
      data = JSON.parse(body)
    rescue JSON::ParserError
      raise DeadProxyError, 'non-JSON response (proxy blocked)'
    end

    nodes = Nokogiri::HTML(data['html'].to_s).css('li.l-vacancy')
    # data['last'] is Dou's explicit last-page flag — the only reliable end signal. It
    # arrives TOGETHER with the final partial page (e.g. `last: true` + 37 items at
    # count=5800 of 5837), so it must not short-circuit before the nodes are parsed:
    # that dropped the tail (total mod 40 vacancies) on every sync. Only "last AND
    # nothing to parse" is the end; the page after the tail returns exactly that.
    # Empty nodes WITHOUT it means the proxy got a blocked/rate-limited (but valid-JSON)
    # response; retry on another IP instead of truncating pagination as if it were the end.
    return if nodes.empty? && data['last'] == true
    raise DeadProxyError, 'empty listing (proxy rate-limited)' if nodes.empty?

    @items_per_page ||= data['num']
    nodes.map { |el| extract_job_data(el) }.compact
  end

  private

  def initialize_session
    response   = via_proxy { @client.get(VACANCIES_URL) }
    csrf_match = Array(response.headers['set-cookie']).join('; ').match(/csrftoken=([^;,\s]+)/)
    @csrf_token = csrf_match&.[](1)
    raise DeadProxyError, 'could not extract CSRF token (proxy blocked)' if @csrf_token.blank?
  end

  def xhr_headers
    {
      'X-Requested-With' => 'XMLHttpRequest',
      'X-CSRFToken'      => @csrf_token.to_s,
      'Referer'          => VACANCIES_URL,
      'Cookie'           => "csrftoken=#{@csrf_token}",
      'Content-Type'     => 'application/x-www-form-urlencoded'
    }
  end

  def extract_job_data(element)
    link_el = element.at_css('a.vt')
    title = link_el&.text&.strip
    path = link_el&.[]('href')&.split('?')&.first
    external_id = path.to_s.match(/\/vacancies\/(\d+)/)&.[](1)

    company_el = element.at_css('a.company')
    company_name = company_el&.children&.select(&:text?)&.map(&:text)&.join&.squish

    # No description here on purpose: Dou's full description comes from the detail page
    # in the second pass (fetches_description? == true). Leaving it nil lets the detail
    # pass target only the vacancies that still need one (new + previously-failed).
    ApplyMate::Operation::Struct.new(
      source_id:        @source.id,
      title:,
      url:              full_url(path),
      company_name:,
      company_icon_url: element.at_css('a.company img.f-i')&.[]('src'),
      external_id:
    )
  end
end
