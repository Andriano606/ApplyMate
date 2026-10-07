# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::Browser::Operation::ReleaseOrphanLeases, type: :operation do
  include_context 'with browserd env'

  let(:sweep_url) { "#{BrowserdEnv::URL}/leases" }
  let(:operation) { described_class.new(owner_prefix: 'apply-host:') }
  let(:model) { operation.tap(&:call).result.model }

  it 'deletes by owner prefix and returns the released count' do
    stub_request(:delete, sweep_url).with(query: { owner: 'apply-host:' },
                                          headers: { 'Authorization' => "Bearer #{BrowserdEnv::TOKEN}" })
                                    .to_return(status: 200, body: '{"released":2}')

    expect(model).to eq(2)
  end

  it 'returns nil and logs a warning on an unexpected status' do
    stub_request(:delete, sweep_url).with(query: hash_including({})).to_return(status: 401)
    allow(Rails.logger).to receive(:warn)

    expect(model).to be_nil
    expect(Rails.logger).to have_received(:warn).with(/browserd.orphan_sweep_failed/)
  end

  it 'returns nil when browserd is unreachable' do
    stub_request(:delete, sweep_url).with(query: hash_including({}))
                                    .to_raise(Faraday::ConnectionFailed.new('Connection refused'))

    expect(model).to be_nil
  end

  it 'returns nil when BROWSERD_URL is unset' do
    allow(ENV).to receive(:fetch).with('BROWSERD_URL') { |_key, &missing| missing.call }

    expect(model).to be_nil
  end

  it 'refuses a blank prefix, which would release every lease' do
    expect { described_class.call(owner_prefix: '') }.to raise_error(ArgumentError)
  end

  describe 'Browserd.owner_prefix' do
    it 'is hostname, app dir and env, so workspaces sharing a host and a browserd never sweep each other' do
      expect(ApplyMate::Client::Browser::Browserd.owner_prefix)
        .to eq("#{Socket.gethostname}:#{Rails.root.basename}:test:")
    end
  end
end
