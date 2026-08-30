# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::Browser do
  let(:network) { double('network', wait_for_idle: nil) }
  let(:page_headers) { double('headers', set: nil) }
  let(:cookies) { double('cookies', all: {}) }
  let(:page) do
    double('page', command: nil, headers: page_headers, network: network,
                   goto: nil, current_url: 'https://jobs.dou.ua/vacancies/', close: nil)
  end
  let(:ferrum) { double('ferrum', create_page: page, cookies: cookies, quit: nil) }

  before { allow(Ferrum::Browser).to receive(:new).and_return(ferrum) }

  describe '#initialize' do
    it 'launches Chrome without a proxy by default' do
      described_class.new
      expect(Ferrum::Browser).to have_received(:new).with(hash_excluding(:proxy))
    end

    it 'routes Chrome through an HTTP proxy' do
      described_class.new(proxy: 'http://10.0.0.1:8080')
      expect(Ferrum::Browser).to have_received(:new)
        .with(hash_including(proxy: { host: '10.0.0.1', port: '8080', type: 'http' }))
    end

    it 'routes Chrome through a SOCKS5 proxy' do
      described_class.new(proxy: 'socks5://1.2.3.4:1080')
      expect(Ferrum::Browser).to have_received(:new)
        .with(hash_including(proxy: { host: '1.2.3.4', port: '1080', type: 'socks5' }))
    end
  end

  describe '#get' do
    subject(:client) { described_class.new(proxy: 'http://1.2.3.4:8080') }

    before { allow(client).to receive(:sleep) }

    it 'injects the stealth script before loading the page' do
      allow(page).to receive(:body).and_return('<html>real</html>')
      client.get('https://jobs.dou.ua/vacancies/')
      expect(page).to have_received(:command)
        .with('Page.addScriptToEvaluateOnNewDocument', source: described_class::STEALTH_SCRIPT)
    end

    it 'returns a 200 Response with the rendered body when no challenge appears' do
      allow(page).to receive(:body).and_return('<html>real vacancies</html>')
      response = client.get('https://jobs.dou.ua/vacancies/')

      expect(response).to be_a(described_class::Response)
      expect(response.status).to eq(200)
      expect(response.body).to eq('<html>real vacancies</html>')
      expect(response.final_url).to eq('https://jobs.dou.ua/vacancies/')
    end

    it 'waits through the Cloudflare challenge (no reload) and returns the cleared page' do
      allow(page).to receive(:body).and_return('<title>Just a moment...</title>', '<html>real page</html>')
      response = client.get('https://jobs.dou.ua/vacancies/')

      expect(response.status).to eq(200)
      expect(response.body).to eq('<html>real page</html>')
      expect(page).to have_received(:goto).once # navigate once; the JS challenge auto-solves
      expect(client).to have_received(:sleep).once
    end

    it 'gives up after CHALLENGE_POLLS checks and returns 403' do
      allow(page).to receive(:body).and_return('<title>Just a moment...</title>')
      response = client.get('https://jobs.dou.ua/vacancies/')

      expect(response.status).to eq(403)
      expect(page).to have_received(:goto).once
      expect(client).to have_received(:sleep).exactly(described_class::CHALLENGE_POLLS).times
    end

    it 'forwards custom request headers (e.g. cookies) to the page' do
      allow(page).to receive(:body).and_return('<html>ok</html>')
      client.get('https://x', headers: { 'Cookie' => 'a=1' })

      expect(page_headers).to have_received(:set).with({ 'Cookie' => 'a=1' })
    end

    it 'always closes the page even when the challenge persists' do
      allow(page).to receive(:body).and_return('<title>Just a moment...</title>')
      client.get('https://x')

      expect(page).to have_received(:close)
    end
  end
end
