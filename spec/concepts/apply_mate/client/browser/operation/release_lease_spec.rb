# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::Browser::Operation::ReleaseLease, type: :operation do
  include_context 'with browserd env'

  let(:lease) { ApplyMate::Client::Browser::Lease.from_json(JSON.parse(BrowserdEnv.lease_json)) }
  let(:lease_url) { "#{BrowserdEnv::URL}/leases/lease-1" }
  let(:operation) { described_class.new(lease:) }
  let(:model) { operation.tap(&:call).result.model }

  it 'deletes the lease with the bearer token' do
    stub_request(:delete, lease_url).with(headers: { 'Authorization' => "Bearer #{BrowserdEnv::TOKEN}" })
                                    .to_return(status: 204)

    expect(model).to be(true)
  end

  it 'treats an already reaped lease (404) as released' do
    stub_request(:delete, lease_url).to_return(status: 404)

    expect(model).to be(true)
  end

  it 'returns false and logs on 409 / 5xx' do
    stub_request(:delete, lease_url).to_return(status: 409)
    allow(Rails.logger).to receive(:warn)

    expect(model).to be(false)
    expect(Rails.logger).to have_received(:warn).with(/browserd.release_failed/)
  end

  it 'never raises when browserd is unreachable' do
    stub_request(:delete, lease_url).to_raise(Faraday::ConnectionFailed.new('Connection refused'))

    expect(model).to be(false)
  end

  it 'never raises when browserd is not configured' do
    allow(ENV).to receive(:fetch).with('BROWSERD_TOKEN') { |_key, &missing| missing.call }

    expect(model).to be(false)
  end
end
