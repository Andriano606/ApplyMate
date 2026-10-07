# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Ai::Client::GeminiScraping do
  subject(:client) { described_class.new(api_key: nil, host: nil, model: nil) }

  let(:browser) { instance_double(Ferrum::Browser, quit: nil) }

  before do
    allow(Ferrum::Browser).to receive(:new).and_return(browser)
  end

  describe '.capabilities' do
    it 'declares browser_backed only' do
      expect(described_class.capabilities).to eq(%i[browser_backed])
      expect(described_class.supports?(:json_schema)).to be(false)
    end
  end

  it 'does not launch a browser when built' do
    client

    expect(Ferrum::Browser).not_to have_received(:new)
  end

  describe '#complete' do
    it 'types the flattened system + messages prompt and wraps the answer with Usage::UNKNOWN' do
      allow(client).to receive(:scrape_answer).and_return('Привіт!')
      request = ApplyMate::Ai::Request.for(kind: :answers, text: 'Say hello', system: 'Answer in Ukrainian')

      response = client.complete(request)

      expect(client).to have_received(:scrape_answer).with("Answer in Ukrainian\n\nSay hello")
      expect(response).to eq(ApplyMate::Ai::Response.new(text: 'Привіт!', usage: ApplyMate::Ai::Usage::UNKNOWN))
    end

    it 'omits a nil system prompt' do
      allow(client).to receive(:scrape_answer).and_return('ok')

      client.complete(ApplyMate::Ai::Request.for(kind: :verify, text: 'Only text'))

      expect(client).to have_received(:scrape_answer).with('Only text')
    end

    it 'raises CapabilityMissing on images before any browser starts' do
      request = ApplyMate::Ai::Request.for(kind: :verify, text: 'x', images: [ { mime_type: 'image/png', data: 'aGk=' } ])

      expect { client.complete(request) }.to raise_error(ApplyMate::Ai::Client::Base::CapabilityMissing, /vision/)
      expect(Ferrum::Browser).not_to have_received(:new)
    end

    it 'quits the browser it launched when scraping fails' do
      allow(browser).to receive(:contexts).and_raise(Ferrum::Error, 'cdp gone')

      expect { client.complete(ApplyMate::Ai::Request.for(kind: :verify, text: 'x')) }
        .to raise_error(Ferrum::Error, 'cdp gone')
      expect(browser).to have_received(:quit)
    end
  end
end
