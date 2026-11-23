# frozen_string_literal: true

# robota.ua — a general (not IT-only) job board, ~100k live vacancies. The site is an
# Angular SPA: its HTML pages are an empty shell without a browser, so both passes read
# the JSON API the SPA itself calls — the search endpoint for the listing and the
# vacancy endpoint for each vacancy's own description.
class ApplyMate::Scraper::Robota < ApplyMate::Scraper::Base
  LISTING_URL  = 'https://robota.ua/zapros/ukraine'
  VACANCY_PAGE = 'https://robota.ua/company%<company_id>s/vacancy%<id>s'
  SEARCH_URL   = 'https://api.robota.ua/vacancy/search'
  VACANCY_URL  = 'https://api.robota.ua/vacancy'
  LOGO_URL     = 'https://logo-frankfurt.cf-rabota.com.ua/'
  DEFAULT_LOGO = 'defaultlogo.gif' # robota's placeholder for "no logo"

  PAGE_SIZE = 100

  # The search API answers `total: 0, documents: []` from offset 80 000 on, whatever the
  # real total — deeper results are unreachable. That is why the listing is split into
  # segments (below), why a page past the window ends its segment without a request, and
  # why a segment reporting a bigger total fails the run (IncompleteListingError).
  MAX_RESULT_WINDOW = 80_000

  # The segments: one search per career level (`profLevelIds`). Every vacancy has
  # exactly one level, so the slices are disjoint and together are the whole listing —
  # measured 2026-11: 844 + 38 318 + 17 335 + 30 571 + 7 892 + 2 722 + 164 = 97 846,
  # the unfiltered total; levels 7+ are empty. The biggest slice is well under
  # MAX_RESULT_WINDOW. Nothing checks the coverage at run time: if robota adds a level,
  # its vacancies are simply never listed — re-measure by hand (`count: 1` with and
  # without `profLevelIds: [n]`) and extend the list. If robota stops honouring the
  # filter, every segment reports the unfiltered total, which is over the window, and
  # the run fails instead of deleting what it couldn't reach.
  PROF_LEVEL_IDS = (0..6).to_a.freeze

  # Cloudflare's block and rate-limit answers: this proxy can't be used here right now.
  BLOCKED_STATUSES = [ 403, 429 ].freeze

  # Any other answer that isn't the JSON we expect (a 5xx, a changed body). Robota's
  # side, not the proxy's — SyncVacancies retries it without marking the proxy dead.
  class UnexpectedResponseError < StandardError; end

  HEADERS = { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }.freeze

  # api.robota.ua is behind Cloudflare and rejects OpenSSL's TLS fingerprint (403
  # "Just a moment…" for AsyncHttp, 200 for curl-impersonate) — same as Dou.
  def self.http_client_class
    ApplyMate::Client::ImpersonateHttp
  end

  # The public search page a person browses — what the totals widget links to.
  def self.listing_url(_source)
    LISTING_URL
  end

  # Proxies are probed against the API both passes call (a GET of the search works),
  # not the SPA shell on robota.ua, which sits behind different Cloudflare rules.
  def self.validation_url(_source)
    "#{SEARCH_URL}?count=1"
  end

  def self.listing_segments
    PROF_LEVEL_IDS
  end

  # Every search page carries the segment's `total`; fetch_listing returns nil only
  # once the page's offset is past it.
  def self.listing_end_reported?
    true
  end

  # The listing carries only a ~250-character teaser; the full description comes from
  # each vacancy's own endpoint in the second pass.
  def self.fetches_description?
    true
  end

  # Cloudflare-fronted and rate-sensitive: one IP firing ~50 requests at once gets the
  # challenge page, so proxies rest between bursts like Dou's.
  def self.burst_cooldown
    5
  end

  def initialize(source, client)
    @source = source
    @client = client
  end

  # `page` is the pipeline's 1-based page within the segment; the API's is 0-based.
  def fetch_listing(page:, segment:)
    offset = (page - 1) * PAGE_SIZE
    return if offset >= MAX_RESULT_WINDOW

    body      = { page: page - 1, count: PAGE_SIZE, profLevelIds: [ segment ] }.to_json
    data      = parse_json(via_proxy { @client.post(SEARCH_URL, body:, headers: HEADERS) })
    total     = data['total']
    vacancies = data['documents']
    raise UnexpectedResponseError, "search answered without total/documents: #{data.keys.first(5)}" unless total.is_a?(Integer) && vacancies.is_a?(Array)

    if total > MAX_RESULT_WINDOW
      raise IncompleteListingError, "segment #{segment.inspect} lists #{total} vacancies, the search reaches #{MAX_RESULT_WINDOW}"
    end

    # `total` comes with every page, so the end is known, not guessed: nothing left past
    # it is the last page. An empty page short of it is a blocked or throttled answer.
    return if vacancies.empty? && offset >= total
    raise DeadProxyError, 'empty listing (proxy rate-limited)' if vacancies.empty?

    vacancies.map { |vacancy| extract_job_data(vacancy) }
  end

  # The vacancy endpoint returns the employer's description as one HTML document — the
  # body of the page's "description" block. Everything else the page shows around it
  # (contacts, the company card, similar and recommended vacancies, the CV promo) comes
  # from other fields and requests, so nothing has to be cut out of it. The salary lives
  # only in the page header, so it is prepended as its own paragraph.
  # Returns nil (the next run retries) when the vacancy is gone or has no description.
  def fetch_description(url)
    id = url.to_s[/vacancy(\d+)/, 1]
    return nil if id.nil?

    response = via_proxy { @client.get("#{VACANCY_URL}?id=#{id}", headers: HEADERS) }
    return nil if response.status == 404 # closed since the listing; the next listing drops it

    data = parse_json(response)
    html = content_html(Nokogiri::HTML(data['description'].to_s).at_css('body'))
    return nil if html.blank?

    [ salary_html(data), html ].compact.join
  end

  private

  # A 200 that isn't JSON is a proxy's own page (captcha, portal), so it counts against
  # the proxy like a Cloudflare block; any other non-200 is robota's answer.
  def parse_json(response)
    raise DeadProxyError, "HTTP #{response.status} (proxy blocked)" if BLOCKED_STATUSES.include?(response.status)
    raise UnexpectedResponseError, "HTTP #{response.status}" unless response.status == 200

    begin
      data = JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      raise DeadProxyError, 'non-JSON response (proxy blocked)'
    end
    raise UnexpectedResponseError, "expected a JSON object, got #{data.class}" unless data.is_a?(Hash)

    data
  end

  def extract_job_data(vacancy)
    # No description on purpose: it comes from the vacancy endpoint in the second pass
    # (fetches_description? == true), which only visits vacancies that still lack one.
    ApplyMate::Operation::Struct.new(
      source_id:        @source.id,
      title:            vacancy['name'].to_s.squish,
      url:              format(VACANCY_PAGE, company_id: vacancy['notebookId'], id: vacancy['id']),
      company_name:     vacancy['companyName'].to_s.squish.presence,
      company_icon_url: logo_url(vacancy['logo']),
      external_id:      vacancy['id'].to_s
    )
  end

  def logo_url(logo)
    return nil if logo.blank? || logo == DEFAULT_LOGO

    "#{LOGO_URL}#{logo}"
  end

  # "Зарплата: 40 000 – 46 000 ₴ · на руки" — a range (salaryFrom + salaryTo) or one
  # figure (salary, or whichever bound is set); nil when the employer gave none.
  def salary_html(data)
    from, to, exact = data.values_at('salaryFrom', 'salaryTo', 'salary').map(&:to_i)
    single = [ exact, from, to ].find(&:positive?)
    amount =
      if from.positive? && to.positive?
        I18n.t('vacancy.sync.salary.range', from: delimited(from), to: delimited(to))
      elsif single
        I18n.t('vacancy.sync.salary.exact', amount: delimited(single))
      end
    return nil if amount.nil?

    text = [ amount, data['salaryComment'].to_s.squish.presence ].compact.join(' · ')
    "<p>#{ERB::Util.html_escape(text)}</p>"
  end

  def delimited(number)
    ActiveSupport::NumberHelper.number_to_delimited(number, delimiter: ' ')
  end
end
