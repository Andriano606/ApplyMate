# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::Response do
  describe '.cloudflare_challenge?' do
    described_class::CLOUDFLARE_MARKERS.each do |marker|
      it "detects #{marker.inspect}" do
        expect(described_class.cloudflare_challenge?("<html><title>#{marker}</title></html>")).to be(true)
      end
    end

    it 'is false for a normal page, an empty body and nil' do
      expect([ '<html><h1>Senior Rails</h1></html>', '', nil ].map { |body| described_class.cloudflare_challenge?(body) })
        .to eq([ false, false, false ])
    end
  end

  describe '.cloudflare_interstitial?' do
    it 'detects the interstitial by its title or cf-chl markers' do
      pages = [ '<title>Just a moment...</title>', '<div id="cf-chl-widget"></div>',
                '<script>window._cf_chl_opt={}</script>' ]

      expect(pages.map { |html| described_class.cloudflare_interstitial?(html) }).to eq([ true, true, true ])
    end

    it 'ignores the bot-management script Cloudflare injects into ordinary pages' do
      html = "<html><body><h1>Careers</h1><script>a.src='/cdn-cgi/challenge-platform/scripts/jsd/main.js'</script>"

      expect(described_class.cloudflare_interstitial?(html)).to be(false)
      expect(described_class.cloudflare_challenge?(html)).to be(true)
    end
  end

  describe '#cloudflare_challenge?' do
    it 'delegates to the class-level predicate' do
      allow(described_class).to receive(:cloudflare_challenge?).and_call_original

      expect(described_class.new('<p>Just a moment...</p>', {}, 403, 'https://x').cloudflare_challenge?).to be(true)
      expect(described_class).to have_received(:cloudflare_challenge?).with('<p>Just a moment...</p>')
    end
  end

  describe '#alive_or_cf_challenge?' do
    it 'accepts 2xx/3xx and a 403 challenge, rejects a plain 403 and a missing status' do
      statuses = [ [ 200, '' ], [ 302, '' ], [ 403, 'cf-chl-x' ], [ 403, 'blocked' ], [ nil, '' ] ]

      expect(statuses.map { |status, body| described_class.new(body, {}, status, nil).alive_or_cf_challenge? })
        .to eq([ true, true, true, false, false ])
    end
  end
end
