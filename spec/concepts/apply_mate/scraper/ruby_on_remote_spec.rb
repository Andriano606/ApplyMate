# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Scraper::RubyOnRemote do
  let(:source)  { create(:source, name: 'RubyOnRemote', base_url: 'https://rubyonremote.com/', scraper: described_class.name) }
  let(:client)  { instance_double(ApplyMate::Client::AsyncHttp) }
  let(:scraper) { described_class.new(source, client) }
  let(:clearance) { { 'Cookie' => 'cf_clearance=tok', 'User-Agent' => 'Chrome/151' } }

  def response(body, status: 200)
    ApplyMate::Client::Response.new(body, {}, status, 'https://rubyonremote.com/remote-jobs/?page=1')
  end

  before { allow(ApplyMate::Client::Clearance).to receive(:headers).and_return(clearance) }

  describe '#fetch_listing' do
    let(:card) do
      <<~HTML
        <a href="/jobs/75294-back-end-engineer-at-codekeeper" class="flex w-full">
          <img alt="Codekeeper Logo" src="https://cdn.rubyonremote.com/b280tu">
          <h2 class="text-lg md:text-xl font-semibold">Back End Engineer</h2>
          <p class="text-base">Codekeeper</p>
          <span>Worldwide</span>
          <p class="font-normal">September 04</p>
        </a>
      HTML
    end

    before { allow(client).to receive(:get).and_return(response("<html><body>#{card}</body></html>")) }

    it 'reads the vacancy out of a listing card' do
      vacancy = scraper.fetch_listing(page: 1).first

      expect(vacancy).to have_attributes(
        external_id: '75294',
        title: 'Back End Engineer',
        company_name: 'Codekeeper',
        company_icon_url: 'https://cdn.rubyonremote.com/b280tu',
        url: 'https://rubyonremote.com/jobs/75294-back-end-engineer-at-codekeeper',
        source_id: source.id
      )
    end

    # The listing has no descriptions at all, so leaving them out is what lets the
    # second pass own both columns (see .ai/docs/sync_vacancies.md).
    it 'leaves the description to the detail pass' do
      vacancy = scraper.fetch_listing(page: 1).first

      expect(vacancy.to_h).not_to include(:description, :description_html)
    end

    it 'sends the clearance headers the host is only readable through' do
      scraper.fetch_listing(page: 1)

      expect(client).to have_received(:get)
        .with('https://rubyonremote.com/remote-jobs/?page=1', headers: clearance)
    end

    # An out-of-range page renders the site chrome with no cards — the board's only
    # end-of-list signal (measured at page 400).
    context 'when the page has no cards' do
      before { allow(client).to receive(:get).and_return(response('<html><body><nav>menu</nav></body></html>')) }

      it 'returns nil to end pagination' do
        expect(scraper.fetch_listing(page: 400)).to be_nil
      end
    end

    # The token outlived its usefulness (Cloudflare shortened it, or the address
    # changed): replaying it for the rest of its cached TTL would 403 every page.
    context 'when the answer is a challenge despite the clearance' do
      before do
        allow(client).to receive(:get).and_return(response('<html><title>Just a moment...</title></html>', status: 403))
        allow(ApplyMate::Client::Clearance).to receive(:forget)
      end

      it 'drops the cached token and reports the page as unfetchable' do
        expect { scraper.fetch_listing(page: 1) }
          .to raise_error(described_class::DeadProxyError, /Cloudflare challenge/)
        expect(ApplyMate::Client::Clearance).to have_received(:forget)
      end
    end

    context 'when the challenge never clears' do
      before do
        allow(ApplyMate::Client::Clearance).to receive(:headers)
          .and_raise(ApplyMate::Client::Clearance::ChallengeError, 'did not clear')
      end

      it 'reports it as the site refusing this address' do
        expect { scraper.fetch_listing(page: 1) }
          .to raise_error(described_class::DeadProxyError, /no Cloudflare clearance/)
      end
    end

    # A host with no Chrome (or no display) is a deploy problem, and dressing it up as
    # DeadProxyError would file it under "the site is blocking us" — the sync would
    # keep retrying and the logs would point at the wrong thing.
    context 'when the host cannot run a browser at all' do
      before do
        allow(ApplyMate::Client::Clearance).to receive(:headers)
          .and_raise(ApplyMate::Client::Clearance::BrowserError, 'no Chrome binary')
      end

      it 'lets the browser failure through unchanged' do
        expect { scraper.fetch_listing(page: 1) }
          .to raise_error(ApplyMate::Client::Clearance::BrowserError, /no Chrome binary/)
      end
    end
  end

  describe '#fetch_description' do
    let(:page_html) do
      <<~HTML
        <html><body>
          <h1>Back End Engineer</h1>
          <div class="prose"><div class="trix-content">
            <p class="lead" style="color:red">Про роботу</p>
            <ul><li>Ruby</li></ul>
            <script>track()</script>
          </div></div>
        </body></html>
      HTML
    end

    before { allow(client).to receive(:get).and_return(response(page_html)) }

    it 'keeps the employer markup and drops what no renderer reads' do
      html = scraper.fetch_description('https://rubyonremote.com/jobs/75294-back-end-engineer')

      expect(html).to include('<p>Про роботу</p>', '<li>Ruby</li>')
      expect(html).not_to include('<script', 'style=', 'class=')
    end

    it 'returns nil when the page carries no description' do
      allow(client).to receive(:get).and_return(response('<html><body><h1>Gone</h1></body></html>'))

      expect(scraper.fetch_description('https://rubyonremote.com/jobs/1')).to be_nil
    end
  end

  describe 'class configuration' do
    # The clearance belongs to the address that earned it. Rotating this source
    # through the shared pool would 403 on every request AND report each proxy as
    # dead, draining the pool Dou and Djinni depend on.
    it 'is scraped from the app host, not through the proxy pool' do
      expect(described_class.uses_proxies?).to be(false)
    end

    it 'takes descriptions from the vacancy pages' do
      expect(described_class.fetches_description?).to be(true)
    end

    it 'validates and links against the real listing' do
      expect(described_class.listing_url(source)).to eq('https://rubyonremote.com/remote-jobs/')
    end
  end
end
