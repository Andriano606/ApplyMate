# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::ProxyMate do
  include_context 'with ProxyMate'

  let(:client) { described_class.new }
  let(:query) do
    { site: 'dou', limit: 1000, order: 'stable', protocols: %w[http socks4 socks5h], cloudflare: 'any', session_id: 'applymate-1-2' }
  end

  describe '#proxies' do
    # A real fields=minimal batch body (ProxyApi::Serializer.batch), trimmed to three proxies.
    before do
      stub_request(:post, proxy_mate_batch_url('dou')).to_return(
        status: 200, headers: { 'Content-Type' => 'application/json' }, body: file_fixture('proxy_mate/batch_dou.json').read
      )
    end

    it 'parses every proxy into a value object' do
      proxies = client.proxies(**query).proxies

      expect(proxies.map(&:id)).to eq([ 18_485, 18_476, 20_311 ])
      expect(proxies.map(&:url)).to eq([ 'socks4://88.245.138.87:1080', 'http://85.117.61.108:8080', 'socks5h://203.0.113.7:1080' ])
      expect(proxies.map(&:protocol)).to eq(%w[socks4 http socks5])
      expect(proxies.first(2).map(&:clearance)).to eq([ nil, nil ])
    end

    it 'keeps the Cloudflare clearance with the UA and fingerprint it is bound to' do
      expect(client.proxies(**query).proxies.last.clearance).to eq(
        described_class::Clearance.new(cookie: 'cf_clearance=Zq8xV1.example-token-1764300040-1.2.1.1',
                                       user_agent: 'Mozilla/5.0 (X11; Linux x86_64; rv:147.0) Gecko/20100101 Firefox/147.0',
                                       impersonate: 'firefox147')
      )
    end

    it 'reads how many proxies the session can still get' do
      batch = client.proxies(**query)

      expect([ batch.available, batch.remaining ]).to eq([ 41, 38 ])
    end

    it 'POSTs the options with the session and fields=minimal as JSON with the bearer key' do
      client.proxies(**query, impersonate_targets: %w[chrome146 firefox147])

      expect(a_request(:post, proxy_mate_batch_url('dou')).with(
        headers: { 'Authorization' => "Bearer #{ProxyMateSupport::API_KEY}", 'Content-Type' => 'application/json' },
        body: { limit: 1000, order: 'stable', protocols: %w[http socks4 socks5h], cloudflare: 'any', session_id: 'applymate-1-2',
                fields: 'minimal', impersonate_targets: %w[chrome146 firefox147] }.to_json
      )).to have_been_made.once
    end

    it 'leaves impersonate_targets out when there are none' do
      client.proxies(**query)

      expect(a_request(:post, proxy_mate_batch_url('dou')).with { |req| !JSON.parse(req.body).key?('impersonate_targets') })
        .to have_been_made.once
    end

    it 'raises RequestError when the batch lacks remaining (an older ProxyMate)' do
      stub_request(:post, proxy_mate_batch_url('dou')).to_return(status: 200, body: { proxies: [], available: 0 }.to_json)

      expect { client.proxies(**query) }.to raise_error(described_class::RequestError, /unexpected body/)
    end

    it 'joins a base URL that ends with a slash' do
      described_class.new(url: "#{ProxyMateSupport::URL}/").proxies(**query)

      expect(a_request(:post, proxy_mate_batch_url('dou'))).to have_been_made.once
    end
  end

  describe 'failures' do
    it 'raises ResponseError with ProxyMate\'s error code on a rejected key' do
      stub_request(:post, proxy_mate_batch_url('dou')).to_return(
        status: 401, headers: { 'Content-Type' => 'application/json' },
        body: { error: 'unauthorized', message: 'Missing or invalid API key (Authorization: Bearer <key>)' }.to_json
      )

      expect { client.proxies(**query) }.to raise_error(described_class::ResponseError) { |error|
        expect(error.http_status).to eq(401)
        expect(error.code).to eq('unauthorized')
        expect(error.message).to include('Missing or invalid API key')
      }
    end

    it 'raises ResponseError for an unknown site' do
      stub_request(:post, proxy_mate_batch_url('dou')).to_return(
        status: 404, body: { error: 'site_not_found', message: "No enabled site 'dou'" }.to_json
      )

      expect { client.proxies(**query) }.to raise_error(described_class::ResponseError, /404 site_not_found/)
    end

    it 'raises RequestError on a timeout' do
      stub_request(:post, proxy_mate_batch_url('dou')).to_timeout

      expect { client.proxies(**query) }.to raise_error(described_class::RequestError, /unreachable/)
    end

    it 'raises RequestError on a non-JSON success body (e.g. a proxy error page)' do
      stub_request(:post, proxy_mate_batch_url('dou')).to_return(status: 200, body: '<html>Bad gateway</html>')

      expect { client.proxies(**query) }.to raise_error(described_class::RequestError, /non-JSON/)
    end

    it 'raises RequestError when the JSON lacks the proxies list' do
      stub_request(:post, proxy_mate_batch_url('dou')).to_return(status: 200, body: { count: 0 }.to_json)

      expect { client.proxies(**query) }.to raise_error(described_class::RequestError, /unexpected body/)
    end

    it 'raises RequestError when a proxy row is not an object' do
      stub_request(:post, proxy_mate_batch_url('dou')).to_return(status: 200, body: { proxies: [ nil, 'x' ] }.to_json)

      expect { client.proxies(**query) }.to raise_error(described_class::RequestError, /unexpected body/)
    end

    it 'raises ConfigurationError before any request when nothing is configured' do
      ENV['PROXY_MATE_API_KEY'] = ''

      expect { client.proxies(**query) }.to raise_error(described_class::ConfigurationError, /not configured/)
      expect(a_request(:any, /proxymate/)).not_to have_been_made
    end
  end

  describe '#sites' do
    let(:sites_url) { "#{ProxyMateSupport::URL}/api/v1/sites" }
    let(:body) do
      { sites: [
        { id: 1, slug: 'djinni', name: 'Djinni', url: 'https://djinni.co/jobs/', working: 880, working_with_clearance: 0 },
        { id: 2, slug: 'dou', name: 'DOU', url: 'https://jobs.dou.ua/', working: 41, working_with_clearance: 7 }
      ] }
    end

    it 'GETs the sites with the bearer key and parses the counts' do
      stub_request(:get, sites_url).to_return(status: 200, body: body.to_json)

      expect(client.sites).to eq([
        described_class::Site.new(slug: 'djinni', name: 'Djinni', working: 880, working_with_clearance: 0),
        described_class::Site.new(slug: 'dou', name: 'DOU', working: 41, working_with_clearance: 7)
      ])
      expect(a_request(:get, sites_url).with(headers: { 'Authorization' => "Bearer #{ProxyMateSupport::API_KEY}" }))
        .to have_been_made.once
    end

    it 'raises ResponseError on a rejected key' do
      stub_request(:get, sites_url).to_return(status: 401, body: { error: 'unauthorized', message: 'bad key' }.to_json)

      expect { client.sites }.to raise_error(described_class::ResponseError) { |error| expect(error.http_status).to eq(401) }
    end

    it 'raises RequestError when unreachable' do
      stub_request(:get, sites_url).to_timeout

      expect { client.sites }.to raise_error(described_class::RequestError, /unreachable/)
    end

    it 'raises RequestError when the JSON lacks the sites list' do
      stub_request(:get, sites_url).to_return(status: 200, body: { count: 0 }.to_json)

      expect { client.sites }.to raise_error(described_class::RequestError, /unexpected body/)
    end
  end

  describe '#meta' do
    it 'parses the curl-impersonate release and its targets' do
      stub_proxy_mate_json(:get, '/api/v1/meta', proxy_mate_meta_body(release: 'v2.3.3'))

      expect(client.meta).to eq(described_class::Meta.new(curl_release: 'v2.3.3', curl_targets: ProxyMateSupport::CURL_TARGETS))
    end

    it 'raises ResponseError on a rejected key' do
      stub_proxy_mate_json(:get, '/api/v1/meta', { error: 'unauthorized', message: 'bad key' }, status: 401)

      expect { client.meta }.to raise_error(described_class::ResponseError) { |error| expect(error.http_status).to eq(401) }
    end
  end

  describe 'configuration precedence' do
    let(:saved_url) { 'http://saved.proxymate.test' }

    before do
      stub_request(:get, /proxymate\.test\/api\/v1\/sites/).to_return(status: 200, body: { sites: [] }.to_json)
    end

    it 'prefers the saved setting over ENV' do
      ProxyMateSetting.create!(url: saved_url, api_key: 'pm_saved_key')

      described_class.new.sites

      expect(a_request(:get, "#{saved_url}/api/v1/sites").with(headers: { 'Authorization' => 'Bearer pm_saved_key' }))
        .to have_been_made.once
    end

    it 'falls back to ENV per field when the saved one is blank' do
      ProxyMateSetting.create!(url: saved_url)

      described_class.new.sites

      expect(a_request(:get, "#{saved_url}/api/v1/sites")
        .with(headers: { 'Authorization' => "Bearer #{ProxyMateSupport::API_KEY}" })).to have_been_made.once
    end

    it 'uses ENV when nothing is saved' do
      described_class.new.sites

      expect(a_request(:get, "#{ProxyMateSupport::URL}/api/v1/sites")).to have_been_made.once
    end

    it 'reads the setting once per client, not per request' do
      client = described_class.new
      ProxyMateSetting.create!(url: saved_url, api_key: 'pm_saved_key')

      client.sites

      expect(a_request(:get, "#{ProxyMateSupport::URL}/api/v1/sites")).to have_been_made.once
    end
  end
end
