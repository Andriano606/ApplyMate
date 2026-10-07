# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::Browser::Operation::AcquireLease, type: :operation do
  include_context 'with browserd env'

  let(:leases_url) { "#{BrowserdEnv::URL}/leases" }
  let(:busy) { { status: 503, headers: { 'Retry-After' => '5' }, body: '{"error":"pool_busy","leases":1,"max":1}' } }
  let(:created) { { status: 201, body: BrowserdEnv.lease_json } }
  let(:operation) { described_class.new(owner: 'host:42:abc', humanize: true, identity: 'apply-abc') }

  before { allow(ApplyMate::Client::Browser::Clock).to receive(:sleep_ms) }

  it 'posts the owner tags with the bearer token and returns the lease' do
    stub_request(:post, leases_url).to_return(created)

    lease = operation.tap(&:call).result.model

    expect(lease).to have_attributes(id: 'lease-1', ws_endpoint: "ws://browserd.test:9301/#{'a' * 64}",
                                     expires_at: Time.utc(2026, 10, 7, 12, 10),
                                     playwright_version: Playwright::COMPATIBLE_PLAYWRIGHT_VERSION)
    expect(a_request(:post, leases_url).with(
      headers: { 'Authorization' => "Bearer #{BrowserdEnv::TOKEN}", 'Content-Type' => 'application/json' },
      body: { owner: 'host:42:abc', humanize: true, identity: 'apply-abc' }.to_json
    )).to have_been_made.once
    expect(ApplyMate::Client::Browser::Clock).not_to have_received(:sleep_ms)
  end

  it 'never prints the ws_endpoint capability' do
    stub_request(:post, leases_url).to_return(created)

    lease = operation.tap(&:call).result.model

    expect([ lease.inspect, lease.to_s ]).to all(satisfy { |text| !text.include?('a' * 64) })
  end

  it 'retries 503 with Retry-After and returns the lease of the third POST' do
    stub_request(:post, leases_url).to_return(busy, busy.merge(headers: {}), created)

    expect(operation.tap(&:call).result.model.id).to eq('lease-1')
    expect(ApplyMate::Client::Browser::Clock).to have_received(:sleep_ms).with(5_000).twice
    expect(a_request(:post, leases_url)).to have_been_made.times(3)
  end

  it 'caps Retry-After at 10 s' do
    stub_request(:post, leases_url).to_return(busy.merge(headers: { 'Retry-After' => '600' }), created)

    operation.call

    expect(ApplyMate::Client::Browser::Clock).to have_received(:sleep_ms).with(10_000).once
  end

  it 'raises PoolBusy after exactly BUSY_ATTEMPTS POSTs, without a trailing sleep' do
    stub_request(:post, leases_url).to_return(busy)

    expect { operation.call }.to raise_error(ApplyMate::Client::Browser::PoolBusy)
    expect(a_request(:post, leases_url)).to have_been_made.times(described_class::BUSY_ATTEMPTS)
    expect(ApplyMate::Client::Browser::Clock).to have_received(:sleep_ms).twice
  end

  it 'releases the lease and raises VersionMismatch when playwright-core differs' do
    stub_request(:post, leases_url).to_return(status: 201, body: BrowserdEnv.lease_json(playwright_version: '1.62.0'))
    release = stub_request(:delete, "#{leases_url}/lease-1").to_return(status: 204)

    expect { operation.call }.to raise_error(ApplyMate::Client::Browser::VersionMismatch, /1\.62\.0/)
    expect(release).to have_been_requested.once
  end

  it 'raises Crashed when browserd refuses the connection' do
    stub_request(:post, leases_url).to_raise(Faraday::ConnectionFailed.new('Connection refused'))

    expect { operation.call }.to raise_error(ApplyMate::Client::Browser::Crashed, /Connection refused/)
  end

  it 'raises Crashed on a timeout' do
    stub_request(:post, leases_url).to_timeout

    expect { operation.call }.to raise_error(ApplyMate::Client::Browser::Crashed)
  end

  [ 401, 422, 500 ].each do |status|
    it "raises Crashed without retrying on #{status}" do
      stub_request(:post, leases_url).to_return(status:, body: '{"error":"x"}')

      expect { operation.call }.to raise_error(ApplyMate::Client::Browser::Crashed, /#{status}/)
      expect(a_request(:post, leases_url)).to have_been_made.once
    end
  end

  it 'raises Crashed on an unreadable 201 body' do
    stub_request(:post, leases_url).to_return(status: 201, body: '{"id":"lease-1"}')

    expect { operation.call }.to raise_error(ApplyMate::Client::Browser::Crashed, /unreadable lease/)
  end

  it 'raises KeyError, not Crashed, when BROWSERD_URL is unset' do
    allow(ENV).to receive(:fetch).with('BROWSERD_URL') { |_key, &missing| missing.call }

    expect { operation.call }.to raise_error(KeyError, /BROWSERD_URL is not set/)
  end
end
