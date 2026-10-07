# frozen_string_literal: true

# For every ApplyMate::Scraper that authenticates with a session cookie. The including
# spec must define `scraper` (an instance of described_class).
RSpec.shared_examples 'a scraper with a session cookie' do |cookie_name|
  describe '.session_cookie_name' do
    it "is #{cookie_name.inspect}" do
      expect(described_class.session_cookie_name).to eq(cookie_name)
    end
  end

  describe '#session_headers' do
    it 'sends the session id under the platform cookie name' do
      expect(scraper.session_headers('abc')).to eq('Cookie' => "#{cookie_name}=abc")
    end

    it 'sends no Cookie header without a session id' do
      expect(scraper.session_headers(nil)).to eq({})
      expect(scraper.session_headers('')).to eq({})
    end
  end
end
