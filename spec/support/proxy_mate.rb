# frozen_string_literal: true

# ProxyMate (the proxy service the vacancy sync takes its proxies from) faked at the HTTP
# level with WebMock. `include_context 'with ProxyMate'` points the real ENV config path
# (PROXY_MATE_URL / PROXY_MATE_API_KEY) at a fake host for the example and stubs the
# run-level lookup (GET /api/v1/meta) with ProxyMate's real shape; an example overrides it
# with its own stub_request. Then:
#
#   stub_proxy_mate('djinni', [ proxy_mate_row(1) ])   # first batch, then [] (remaining: 0) for every refill
#   expect(a_request(:post, proxy_mate_batch_url('djinni'))).to have_been_made.once
#   proxy_mate_bodies(:post, proxy_mate_batch_url('djinni'))   # the JSON bodies the sync sent
module ProxyMateSupport
  URL     = 'http://proxymate.test'
  API_KEY = 'pm_test_key'

  CURL_TARGETS = %w[chrome146 firefox133 firefox135 firefox144 firefox147 firefox153 firefox154 firefox155].freeze

  def proxy_mate_batch_url(site)
    "#{URL}/api/v1/sites/#{site}/proxies/batch"
  end

  # One entry of a fields=minimal batch, shaped like ProxyApi::Serializer.batch_proxy_minimal.
  def proxy_mate_row(id, url: "http://10.0.0.#{(id % 250) + 1}:8080", cloudflare: nil)
    { id: id, url: url, protocol: URI.parse(url).scheme.delete_suffix('h'), needs_cloudflare_token: !cloudflare.nil?,
      cloudflare: cloudflare, stability: { score: 50 } }
  end

  # The first request gets `proxies`; every later one (refills) gets an empty list and remaining: 0.
  def stub_proxy_mate(site, proxies)
    stub_request(:post, proxy_mate_batch_url(site))
      .to_return(proxy_mate_response(proxies), proxy_mate_response([]))
  end

  def proxy_mate_response(proxies, remaining: 0, status: 200)
    { status: status, headers: { 'Content-Type' => 'application/json' },
      body: { count: proxies.size, available: proxies.size + remaining, remaining: remaining, fields: 'minimal',
              next_cursor: nil, proxies: proxies }.to_json }
  end

  def proxy_mate_meta_body(release: ApplyMate::Client::ImpersonateHttp::RELEASE, targets: CURL_TARGETS)
    { curl_impersonate: { release: release, version: nil, default_target: 'chrome146', cloudflare_targets: targets - [ 'chrome146' ],
                          targets: targets, targets_in_use: [ 'chrome146' ] },
      sessions: { ttl_hours: 24 } }
  end

  def stub_proxy_mate_json(verb, path, body, status: 200)
    stub_request(verb, "#{URL}#{path}")
      .to_return(status: status, headers: { 'Content-Type' => 'application/json' }, body: body.to_json)
  end

  # The JSON body of every `verb` request to `url`, parsed (string keys, as sent).
  def proxy_mate_bodies(verb, url)
    pattern = WebMock::RequestPattern.new(verb, url)
    WebMock::RequestRegistry.instance.requested_signatures.hash
                            .select { |signature, _| pattern.matches?(signature) }
                            .flat_map { |signature, count| Array.new(count) { JSON.parse(signature.body) } }
  end
end

RSpec.shared_context 'with ProxyMate' do
  around do |example|
    saved = ENV.to_h.slice('PROXY_MATE_URL', 'PROXY_MATE_API_KEY')
    ENV['PROXY_MATE_URL']     = ProxyMateSupport::URL
    ENV['PROXY_MATE_API_KEY'] = ProxyMateSupport::API_KEY
    example.run
  ensure
    %w[PROXY_MATE_URL PROXY_MATE_API_KEY].each { |key| ENV[key] = saved[key] }
  end

  before do
    stub_proxy_mate_json(:get, '/api/v1/meta', proxy_mate_meta_body)
  end
end

RSpec.configure { |config| config.include ProxyMateSupport }
