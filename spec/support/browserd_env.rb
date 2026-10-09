# frozen_string_literal: true

# Points ApplyMate::Client::Browser::Browserd at a WebMock host for lease-client specs:
#   include_context 'with browserd env'
#   stub_request(:post, "#{BrowserdEnv::URL}/leases")
module BrowserdEnv
  URL = 'http://browserd.test:9300'
  TOKEN = 'test-browserd-token-0123456789'

  def self.lease_json(**overrides)
    {
      id: 'lease-1', ws_endpoint: "ws://browserd.test:9301/#{'a' * 64}", expires_at: '2026-10-07T12:10:00.000Z',
      playwright_version: Playwright::COMPATIBLE_PLAYWRIGHT_VERSION, browser_version: '156.0.1-beta.36', identity: nil
    }.merge(overrides).to_json
  end
end

RSpec.shared_context 'with browserd env' do
  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('BROWSERD_URL').and_return(BrowserdEnv::URL)
    allow(ENV).to receive(:fetch).with('BROWSERD_TOKEN').and_return(BrowserdEnv::TOKEN)
  end
end
