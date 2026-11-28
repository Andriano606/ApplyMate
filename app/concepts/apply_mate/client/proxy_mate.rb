# frozen_string_literal: true

require 'net/http'
require 'timeout'

# JSON API client for ProxyMate — the separate service that collects proxies, checks each
# one on each job site with curl-impersonate, scores their stability and obtains Cloudflare
# cf_clearance tokens. ApplyMate keeps no proxy state of its own: the vacancy sync asks
# ProxyMate for working proxies per site in one session per run and source
# (Vacancy::Operation::SyncVacancies::ProxyPool). It reports nothing back: a proxy that fails
# this run just leaves the run's pool.
#
# Config, read once per client (one client per sync run), each value taking the first present of:
#   1. the setting an admin saved on the ProxyMate admin page (ProxyMateSetting: URL + encrypted key)
#   2. ENV PROXY_MATE_URL (base URL, e.g. http://localhost:3010) / PROXY_MATE_API_KEY (sent as
#      `Authorization: Bearer <key>`) — kept for dev
# A missing value raises ConfigurationError on the first request, before any I/O.
#
# Plain Net::HTTP: under the Async fiber scheduler its socket waits, DNS and Timeout yield
# to the reactor, and outside a reactor (seeding the pools) it simply blocks. Every request
# is bounded by OPEN_TIMEOUT / READ_TIMEOUT and an overall REQUEST_TIMEOUT. Net::HTTP is
# also what WebMock intercepts, so specs stub this API at the HTTP level.
class ApplyMate::Client::ProxyMate
  Error              = Class.new(StandardError)
  ConfigurationError = Class.new(Error)
  RequestError       = Class.new(Error) # transport failure, timeout, unparseable body

  class ResponseError < Error # ProxyMate answered with a non-2xx status
    attr_reader :http_status, :code

    def initialize(http_status, code, message)
      @http_status = http_status
      @code        = code
      super("ProxyMate HTTP #{http_status} #{code}: #{message}")
    end
  end

  # One working proxy for one site. `clearance` is present only when ProxyMate holds a usable
  # cf_clearance token for this proxy on that site; Cloudflare binds it to the proxy IP, the
  # User-Agent and the TLS fingerprint (`impersonate`, a curl-impersonate target).
  Proxy     = Data.define(:id, :url, :protocol, :clearance)
  Clearance = Data.define(:cookie, :user_agent, :impersonate)

  # One batch: the proxies plus `available` (how many the filters and the session allowed
  # before this batch) and `remaining` (how many are left after it; 0 = the session has had
  # every proxy ProxyMate can give for these filters right now).
  Batch = Data.define(:proxies, :available, :remaining)

  # One site ProxyMate checks proxies against; `working` / `working_with_clearance` are proxy counts.
  Site = Data.define(:slug, :name, :working, :working_with_clearance)

  # GET /api/v1/meta: ProxyMate's curl-impersonate release and the targets it hands out.
  Meta = Data.define(:curl_release, :curl_targets)

  OPEN_TIMEOUT    = 3
  READ_TIMEOUT    = 10
  REQUEST_TIMEOUT = 15
  MAX_LIMIT       = 1_000 # ProxyApi::Params::MAX_LIMIT on the ProxyMate side
  FIELDS          = 'minimal' # only what a scraper needs per proxy (ProxyApi::Serializer.batch_proxy_minimal)

  # `url:` / `api_key:` override the configured value (nil = use the configured one).
  def initialize(url: nil, api_key: nil)
    setting  = ProxyMateSetting.current
    @url     = url.presence || setting.effective_url
    @api_key = api_key.presence || setting.effective_api_key
  end

  # The next batch of working proxies for `site` (a ProxyMate site slug, see Scraper.proxy_site)
  # in the scraper run `session_id`: ProxyMate never hands the session the same proxy twice.
  # `impersonate_targets` (optional) — only proxies whose Cloudflare token, if they need one,
  # is bound to one of these curl-impersonate targets. Returns a Batch.
  def proxies(site:, limit:, order:, protocols:, cloudflare:, session_id:, impersonate_targets: nil)
    payload = { limit: limit, order: order, protocols: protocols, cloudflare: cloudflare, session_id: session_id, fields: FIELDS }
    payload[:impersonate_targets] = impersonate_targets if impersonate_targets.present?
    body = request_json(:post, "#{site_path(site)}/proxies/batch", payload)
    Batch.new(proxies: Array(body.fetch('proxies')).map { |row| parse_proxy(row) },
              available: Integer(body.fetch('available')), remaining: Integer(body.fetch('remaining')))
  rescue KeyError, TypeError, ArgumentError, NoMethodError => e
    raise RequestError, unexpected_body_message(e)
  end

  # How many working proxies ProxyMate holds per site (GET /api/v1/sites), e.g. to check the
  # connection. Returns an Array of Site.
  def sites
    body = request_json(:get, '/api/v1/sites')
    Array(body.fetch('sites')).map { |row| parse_site(row) }
  rescue KeyError, TypeError, ArgumentError, NoMethodError => e
    raise RequestError, unexpected_body_message(e)
  end

  # curl-impersonate build and targets (GET /api/v1/meta). Returns a Meta.
  def meta
    body = request_json(:get, '/api/v1/meta')
    curl = body.fetch('curl_impersonate')
    Meta.new(curl_release: curl.fetch('release').to_s, curl_targets: Array(curl.fetch('targets')).map(&:to_s))
  rescue KeyError, TypeError, ArgumentError, NoMethodError => e
    raise RequestError, unexpected_body_message(e)
  end

  private

  def site_path(site)
    "/api/v1/sites/#{ERB::Util.url_encode(site)}"
  end

  def unexpected_body_message(error)
    "ProxyMate returned an unexpected body (#{error.class}: #{error.message})"
  end

  def request_json(verb, path, payload = nil)
    unless @url && @api_key
      raise ConfigurationError,
            'ProxyMate is not configured: save its URL and API key on /admin/proxy_mate (or set PROXY_MATE_URL and PROXY_MATE_API_KEY)'
    end

    uri      = URI.join(@url.end_with?('/') ? @url : "#{@url}/", path.delete_prefix('/'))
    response = transport(verb, uri, payload&.to_json)
    body     = parse_json(response.body)

    unless response.is_a?(Net::HTTPSuccess)
      raise ResponseError.new(response.code.to_i, body&.dig('error'), body&.dig('message') || response.body.to_s.truncate(200))
    end
    raise RequestError, "ProxyMate returned a non-JSON body (HTTP #{response.code})" unless body

    body
  end

  def transport(verb, uri, json)
    http = Net::HTTP.new(uri.host, uri.port, nil) # nil: never route through ENV http_proxy
    http.use_ssl       = uri.scheme == 'https'
    http.open_timeout  = OPEN_TIMEOUT
    http.read_timeout  = READ_TIMEOUT
    http.write_timeout = READ_TIMEOUT

    request = (verb == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri)
    request['Authorization'] = "Bearer #{@api_key}"
    request['Accept']        = 'application/json'
    if json
      request['Content-Type'] = 'application/json'
      request.body            = json
    end

    Timeout.timeout(REQUEST_TIMEOUT) { http.start { |connection| connection.request(request) } }
  rescue StandardError => e
    raise RequestError, "ProxyMate unreachable at #{uri.host}:#{uri.port} (#{e.class}: #{e.message.to_s.truncate(160)})"
  end

  # A JSON object, or nil for an empty / non-JSON / non-object body.
  def parse_json(raw)
    data = JSON.parse(raw.to_s)
    data if data.is_a?(Hash)
  rescue JSON::ParserError
    nil
  end

  def parse_proxy(row)
    Proxy.new(id: Integer(row.fetch('id')), url: row.fetch('url'), protocol: row.fetch('protocol'),
              clearance: parse_clearance(row['cloudflare']))
  end

  def parse_site(row)
    Site.new(slug: row.fetch('slug'), name: row.fetch('name'),
             working: Integer(row.fetch('working')), working_with_clearance: Integer(row.fetch('working_with_clearance')))
  end

  def parse_clearance(data)
    return nil unless data.is_a?(Hash)

    values = data.values_at('cookie', 'user_agent', 'impersonate')
    return nil if values.any?(&:blank?)

    Clearance.new(*values)
  end
end
