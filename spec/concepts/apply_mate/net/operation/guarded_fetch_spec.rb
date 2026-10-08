# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Net::Operation::GuardedFetch do
  let(:http) { ApplyMate::Client::ImpersonateHttp.new }
  let(:resolver) { instance_double(Resolv) }

  before do
    allow(Resolv).to receive(:new).and_return(resolver)
    allow(resolver).to receive(:getaddresses).with('jobs.example.com').and_return([ '203.0.113.7' ])
    allow(resolver).to receive(:getaddresses).with('intranet.example.com').and_return([ '192.168.1.10' ])
    allow(Open3).to receive(:capture3) do |*args|
      @argv = args
      File.write(args[args.index('-o') + 1], 'moved')
      File.write(args[args.index('-D') + 1], "HTTP/1.1 302 Found\r\nLocation: https://jobs.example.com/next\r\n")
      [ '302', '', instance_double(Process::Status, success?: true) ]
    end
  end

  it 'checks the URL, then makes one request pinned to the checked address without following redirects' do
    response = described_class.call(url: 'https://jobs.example.com/apply?id=1', http:).model

    expect(response).to have_attributes(status: 302, final_url: 'https://jobs.example.com/apply?id=1')
    expect(response.headers['location']).to eq('https://jobs.example.com/next')
    expect(@argv[@argv.index('--resolve') + 1]).to eq('jobs.example.com:443:203.0.113.7')
    expect(@argv).not_to include('-L')
  end

  it 'pins a POST the same way and sends its body' do
    described_class.call(url: 'https://jobs.example.com/api', http:, method: :post, body: '{"q":1}',
                         headers: { 'Content-Type' => 'application/json' })

    expect(@argv).to include('-X', 'POST', '-H', 'Content-Type: application/json')
    expect(@argv[@argv.index('--resolve') + 1]).to eq('jobs.example.com:443:203.0.113.7')
  end

  it 'raises UnsafeUrlError before any request for a private host' do
    expect { described_class.call(url: 'http://intranet.example.com/admin', http:) }
      .to raise_error(ApplyMate::Net::UnsafeUrlError) { |error| expect(error.reason).to eq(:private) }
    expect { described_class.call(url: 'http://127.0.0.1:3000/', http:) }.to raise_error(ApplyMate::Net::UnsafeUrlError)
    expect(Open3).not_to have_received(:capture3)
  end

  it 'refuses a client that cannot pin the address' do
    expect { described_class.call(url: 'https://jobs.example.com/', http: ApplyMate::Client::AsyncHttp.new) }
      .to raise_error(ArgumentError, /ImpersonateHttp/)
    expect(Open3).not_to have_received(:capture3)
  end
end
