# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::ImpersonateHttp::ReadOnly do
  subject(:client) { described_class.new }

  before { allow(Open3).to receive(:capture3) }

  it 'refuses a POST before curl runs' do
    expect { client.post('https://jobs.ashbyhq.com/api/non-user-graphql', body: '{}') }
      .to raise_error(ApplyMate::Client::ImpersonateHttp::RequestError, /read-only client: POST/)
    expect(Open3).not_to have_received(:capture3)
  end

  it 'refuses a multipart POST before curl runs' do
    expect { client.post_multipart('https://example.com/apply', payload: { 'a' => 'b' }) }
      .to raise_error(ApplyMate::Client::ImpersonateHttp::RequestError)
    expect(Open3).not_to have_received(:capture3)
  end

  it 'refuses the POST of a pinned GuardedFetch too' do
    resolution = ApplyMate::Net::Operation::ResolvePublicAddress::Resolution.new(url: 'https://example.com/x',
                                                                                 host: 'example.com', port: 443,
                                                                                 ip: '93.184.215.14')
    allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call)
      .and_return(instance_double(ApplyMate::Operation::Result, model: resolution))

    expect do
      ApplyMate::Net::Operation::GuardedFetch.call(url: 'https://example.com/x', http: client, method: :post, body: '{}')
    end.to raise_error(ApplyMate::Client::ImpersonateHttp::RequestError)
    expect(Open3).not_to have_received(:capture3)
  end
end
