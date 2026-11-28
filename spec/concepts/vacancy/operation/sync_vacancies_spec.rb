# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Vacancy::Operation::SyncVacancies, type: :operation do
  include_context 'with ProxyMate'

  # One working proxy per site unless an example says otherwise; every refill gets [].
  let(:djinni_proxies) { [ proxy_mate_row(1) ] }
  let(:dou_proxies)    { [ proxy_mate_row(1) ] }

  before do
    stub_proxy_mate('djinni', djinni_proxies)
    stub_proxy_mate('dou', dou_proxies)
    # Reduce async concurrency so tests finish instantly instead of spinning
    # through thousands of fiber iterations with mocked HTTP responses.
    stub_const('Vacancy::Operation::SyncVacancies::WORKERS_PER_SOURCE', 1)
    stub_const('Vacancy::Operation::SyncVacancies::DESCRIPTION_WORKERS', 1)
    stub_const('Vacancy::Operation::SyncVacancies::MAX_PAGES', 3)
    stub_const('Vacancy::Operation::SyncVacancies::LAST_PAGE_CONFIRMATIONS', 1)
    # Refill only once the pool is empty, without waiting: a run with one proxy finishes in
    # milliseconds, and the dead-proxy examples must not idle through REFILL_INTERVAL.
    stub_const('Vacancy::Operation::SyncVacancies::ProxyPool::MIN_READY', 1)
    stub_const('Vacancy::Operation::SyncVacancies::ProxyPool::REFILL_INTERVAL', 0)
    # Lift the per-proxy use limit so the handful of test proxies serve every request at once;
    # MAX_USES / USE_INTERVAL themselves are covered in sync_vacancies_proxy_pool_spec.rb.
    stub_const('Vacancy::Operation::SyncVacancies::ProxyPool::USE_INTERVAL', 0)
    stub_const('Vacancy::Operation::SyncVacancies::ProxyPool::MAX_USES', 1_000)
    # Stub Elasticsearch import on Vacancy relation
    without_partial_double_verification do
      allow_any_instance_of(ActiveRecord::Relation).to receive(:import)
    end
    # Stub sleep to avoid real delays in tests
    allow_any_instance_of(ApplyMate::Scraper::Djinni).to receive(:sleep)
    allow_any_instance_of(ApplyMate::Scraper::Dou).to receive(:sleep)
  end

  describe 'Djinni source' do
    let!(:source_djinni) { create(:source, name: 'Djinni', base_url: 'https://djinni.co', scraper: 'ApplyMate::Scraper::Djinni') }
    let(:djinni_html_content) { file_fixture('djinni/list/vacancies_page.html').read }
    let(:operation) { described_class.new(sources: [ source_djinni ]) }

    before do
      # Stub the HTTP client to return the Djinni fixture. Out-of-range pages redirect
      # to /jobs/ — that (final_url == JOB_LIST_URL), not an empty body, is the real
      # last-page signal the scraper relies on.
      allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get).with(a_string_including('djinni.co')) do |_instance, url|
        if url.include?('page=1') || !url.include?('page=')
          ApplyMate::Client::ImpersonateHttp::Response.new(djinni_html_content, {}, 200, url)
        else
          ApplyMate::Client::ImpersonateHttp::Response.new('', {}, 200, ApplyMate::Scraper::Djinni::JOB_LIST_URL)
        end
      end
    end

    it 'syncs 15 vacancies' do
      expect {
        operation.call
      }.to change { source_djinni.vacancies.count }.by(15)
    end

    # The totals widget caches per-source counts for 5 minutes; without this the page
    # keeps showing the previous run's numbers after a sync (test cache is a null_store,
    # so the call itself is the observable).
    it 'expires the cached per-source totals once the source is synced' do
      expect(Vacancy::Operation::CountBySource).to receive(:expire!).at_least(:once)

      operation.call
    end

    # The host losing curl mid-run is not a proxy failure: the run stops, but the pages already
    # scraped are still saved and no proxy is counted dead.
    it 'keeps already-scraped vacancies when curl-impersonate stops working mid-run' do
      allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get).with(a_string_including('djinni.co')) do |_instance, url|
        raise ApplyMate::Client::ImpersonateHttp::BinaryError, 'gone' unless url.include?('page=1')

        ApplyMate::Client::ImpersonateHttp::Response.new(djinni_html_content, {}, 200, url)
      end

      events = capture_logged_events

      expect { operation.call }.to change { source_djinni.vacancies.count }.by(15)
      expect(events.find { |e| e['event'] == 'vacancy_sync_listing_finished' }).to include('dead_proxies' => 0)
    end

    it 'updates existing vacancies' do
      existing_vacancy = create(:vacancy, source: source_djinni, external_id: '860253', title: 'Old Title')
      operation.call
      expect(existing_vacancy.reload.title).to eq('Java Developer')
    end

    it 'removes stale vacancies' do
      stale_vacancy = create(:vacancy, source: source_djinni, external_id: 'stale_id')
      operation.call
      expect(Vacancy.find_by(id: stale_vacancy.id)).to be_nil
    end

    it 'correctly parses all fields' do
      operation.call
      vacancy = source_djinni.vacancies.find_by(external_id: '799019')

      expect(vacancy).to be_present
      expect(vacancy.title).to eq('UI / Visual Designer — eCommerce (Flowers and Gifts, US/Canada)')
      expect(vacancy.company_name).to eq('Lime Vizio')
      expect(vacancy.url).to eq('https://djinni.co/jobs/799019-ui-visual-designer-ecommerce-flowers-and-gift/')
      expect(vacancy.company_icon_url).to eq('https://p.djinni.co/55/69eb49944219b5db50dbec7b84c3d6/lime_vizio_inc_logo_400.jpeg')
      expect(vacancy.description).to include('Lime Vizio runs 6 eCommerce brands')
      # Djinni's description comes from the listing, so the markup is stored there too.
      expect(vacancy.description_html).to include('<p>')
      expect(vacancy.description_html).to include('Lime Vizio runs 6 eCommerce brands')
    end

    it 'asks ProxyMate for djinni proxies in one session of the run, with tokens curl-impersonate can replay' do
      events = capture_logged_events

      operation.call

      session = events.find { |e| e['event'] == 'vacancy_sync_started' }['session_id']
      expect(a_request(:post, proxy_mate_batch_url('djinni')).with(
        headers: { 'Authorization' => "Bearer #{ProxyMateSupport::API_KEY}" },
        body: {
          limit: 1000, order: 'stable', protocols: ApplyMate::Client::ImpersonateHttp.supported_proxy_protocols,
          cloudflare: 'any', session_id: "applymate-#{session}-#{source_djinni.id}", fields: 'minimal',
          impersonate_targets: ProxyMateSupport::CURL_TARGETS
        }.to_json
      )).to have_been_made.once
      expect("applymate-#{session}-#{source_djinni.id}").to match(/\A[\w.:-]{1,100}\z/) # ProxyApi::Session::ID_FORMAT
    end

    it 'does not visit vacancy pages — the listing already carries the description' do
      expect_any_instance_of(ApplyMate::Scraper::Djinni).not_to receive(:fetch_description)

      operation.call
    end

    # These events feed the Grafana dashboard (.ai/docs/observability.md); the field
    # names are its contract.
    it 'reports the run to Grafana: pool, listing summary with new/stale counts, result' do
      create(:vacancy, source: source_djinni, external_id: '860253')
      create(:vacancy, source: source_djinni, external_id: 'stale_id')
      events = capture_logged_events

      operation.call

      by_name = events.index_by { |e| e['event'] }
      session = by_name.fetch('vacancy_sync_started')['session_id']
      expect(by_name.fetch('vacancy_sync_started')).to include('sources' => 'Djinni', 'started_at_ms' => session)
      expect(by_name.fetch('vacancy_sync_proxy_pool_ready'))
        .to include('session_id' => session, 'source' => 'Djinni', 'alive' => 1, 'with_clearance' => 0, 'level' => 'info')
      expect(by_name.fetch('vacancy_sync_listing_finished')).to include(
        'session_id' => session, 'source' => 'Djinni', 'result' => 'ok', 'level' => 'info',
        'pages' => 1, 'vacancies' => 15, 'new_vacancies' => 14, 'stale_deleted' => 1, 'vacancies_total' => 15,
        'dead_proxies' => 0, 'failed_requests' => 0, 'errors' => nil, 'retired_proxies' => 0, 'proxy_rounds' => 1
      )
      expect(by_name.fetch('vacancy_sync_listing_finished')['requests']).to be >= 2 # page 1 + the empty last page
      expect(by_name).not_to have_key('vacancy_sync_descriptions_finished')
      expect(by_name.fetch('vacancy_sync_finished')).to include(
        'session_id' => session, 'result' => 'ok', 'sources_ok' => 1, 'sources_failed' => 0,
        'operation' => described_class.name
      )
    end

    context 'when a page within the scraped range returns empty on first request (anti-scraping)' do
      # Two proxies so both fibers can run concurrently without hitting the NO PROXY sleep path.
      let(:djinni_proxies) { [ proxy_mate_row(1), proxy_mate_row(2) ] }

      before do
        stub_const('Vacancy::Operation::SyncVacancies::WORKERS_PER_SOURCE', 2)

        @page1_calls = 0

        # First request to page 1 returns a blocked page (200, no job nodes, NO redirect) —
        # the scraper treats that as a dead proxy and raises, so the page is retried on
        # another proxy and page 1 is fetched twice. Page 3+ redirects to /jobs/ (the real
        # last page). sleep(0.05) yields so fiber 2 can scrape page 2 meanwhile.
        allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get)
          .with(a_string_including('djinni.co')) do |_instance, url|
            if url.include?('page=1') || !url.include?('page=')
              sleep(0.05)
              @page1_calls += 1
              body = @page1_calls == 1 ? '<html><body></body></html>' : djinni_html_content
              ApplyMate::Client::ImpersonateHttp::Response.new(body, {}, 200, url)
            elsif url.include?('page=2')
              ApplyMate::Client::ImpersonateHttp::Response.new(djinni_html_content, {}, 200, url)
            else
              ApplyMate::Client::ImpersonateHttp::Response.new('', {}, 200, ApplyMate::Scraper::Djinni::JOB_LIST_URL)
            end
          end
      end

      it 'retries the blocked page instead of treating it as the last page, dropping the proxy' do
        events = capture_logged_events

        operation.call

        expect(@page1_calls).to eq(2)
        expect(events.find { |e| e['event'] == 'vacancy_sync_listing_finished' }).to include('dead_proxies' => 1)
      end
    end
  end

  describe 'DOU source' do
    let!(:source_dou) { create(:source, name: 'Dou', base_url: 'https://jobs.dou.ua', scraper: 'ApplyMate::Scraper::Dou') }
    let(:dou_html_content) { file_fixture('dou/list/vacancies_page.html').read }
    let(:operation) { described_class.new(sources: [ source_dou ]) }

    before do
      # Every source is driven through ImpersonateHttp (Scraper.http_client_class);
      # stub that client.
      # Stub the HTTP client to return sequential detail files for DOU vacancies
      allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get).with(a_string_including('jobs.dou.ua/companies/')) do |_instance, _url|
        @dou_detail_index ||= 0
        @dou_detail_index += 1
        @dou_detail_index = 1 if @dou_detail_index > 20
        ApplyMate::Client::ImpersonateHttp::Response.new(file_fixture("dou/list/details/#{@dou_detail_index}.html").read, {}, 200)
      end

      # Stub DOU XHR listing: page 1 (count=0) returns vacancies; subsequent pages
      # return empty HTML with last:true so the scraper stops pagination naturally.
      allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:post)
        .with(ApplyMate::Scraper::Dou::XHR_URL, any_args) do |_instance, url, body:, **|
          count = URI.decode_www_form(body.to_s).to_h['count'].to_i
          response_body = count == 0 ? { html: dou_html_content, last: false }.to_json
                                     : { html: '', last: true }.to_json
          ApplyMate::Client::ImpersonateHttp::Response.new(response_body, {}, 200, url)
        end

      # Stub DOU session initialization
      allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get).with(
        ApplyMate::Scraper::Dou::VACANCIES_URL
      ).and_return(ApplyMate::Client::ImpersonateHttp::Response.new('', { 'set-cookie' => 'csrftoken=test_token;' }, 200))
    end

    it 'syncs 20 vacancies' do
      expect {
        operation.call
      }.to change { source_dou.vacancies.count }.by(20)
    end

    it 'updates existing vacancies' do
      existing_vacancy = create(:vacancy, source: source_dou, external_id: '355313', title: 'Old Title')
      operation.call
      expect(existing_vacancy.reload.title).to eq('Account Executive')
    end

    it 'removes stale vacancies' do
      stale_vacancy = create(:vacancy, source: source_dou, external_id: 'stale_id')
      operation.call
      expect(Vacancy.find_by(id: stale_vacancy.id)).to be_nil
    end

    it 'correctly parses all fields' do
      operation.call
      # Vacancy 357292 (Senior Customer Success Manager at GrowthBand)
      vacancy = source_dou.vacancies.find_by(external_id: '357292')

      expect(vacancy).to be_present
      expect(vacancy.title).to eq('Senior Customer Success Manager')
      expect(vacancy.company_name).to eq('GrowthBand')
      expect(vacancy.url).to eq('https://jobs.dou.ua/companies/growthband/vacancies/357292/')
      expect(vacancy.company_icon_url).to eq('https://s.dou.ua/img/static/favicons/32_pWIJ8Qp.png')

      # Verify that the description was scraped correctly from the detail fixture
      # Taking a significant block from the first 20 lines for comparison
      expect(vacancy.description).to include('віддалено $1800–2500')
      expect(vacancy.description).to include('GrowthBand runs done-for-you lead generation for mid-market B2B companies')
      expect(vacancy.description).to include('You own the client relationship completely')
    end

    it 'keeps the employer markup so the vacancy page can render it' do
      operation.call
      vacancy = source_dou.vacancies.find_by(external_id: '357292')

      expect(vacancy.description_html).to include('<p><strong>TL;DR</strong></p>')
      expect(vacancy.description_html).to include('<li>')
      # The tracking script inside the detail page must never reach the database.
      expect(vacancy.description_html).not_to include('<script')
      # …and the plain-text column stays a projection of that same markup.
      expect(vacancy.description).not_to include('<p>')
      expect(vacancy.description).to include('TL;DR')
    end

    it 'asks ProxyMate for dou proxies including ones that carry a Cloudflare clearance' do
      operation.call

      expect(a_request(:post, proxy_mate_batch_url('dou'))
        .with(body: hash_including('cloudflare' => 'any', 'protocols' => ApplyMate::Client::ImpersonateHttp.supported_proxy_protocols,
                                   'impersonate_targets' => ProxyMateSupport::CURL_TARGETS)))
        .to have_been_made.at_least_once
    end

    context 'when ProxyMate runs another curl-impersonate release' do
      before { stub_proxy_mate_json(:get, '/api/v1/meta', proxy_mate_meta_body(release: 'v9.9.9')) }

      it 'asks only for tokens bound to our default target and says why' do
        events = capture_logged_events

        operation.call

        expect(a_request(:post, proxy_mate_batch_url('dou')).with(body: hash_including('impersonate_targets' => [ 'chrome146' ])))
          .to have_been_made.at_least_once
        expect(events.find { |e| e['event'] == 'vacancy_sync_curl_impersonate_mismatch' }).to include(
          'release' => ApplyMate::Client::ImpersonateHttp::RELEASE, 'proxy_mate_release' => 'v9.9.9', 'level' => 'warn'
        )
      end
    end

    context 'when ProxyMate meta is unavailable' do
      before { stub_request(:get, "#{ProxyMateSupport::URL}/api/v1/meta").to_timeout }

      it 'still syncs, asking only for our default target' do
        events = capture_logged_events

        expect { operation.call }.to change { source_dou.vacancies.count }.by(20)
        expect(a_request(:post, proxy_mate_batch_url('dou')).with(body: hash_including('impersonate_targets' => [ 'chrome146' ])))
          .to have_been_made.at_least_once
        expect(events.find { |e| e['event'] == 'vacancy_sync_proxy_mate_lookup_failed' }).to include('lookup' => 'meta', 'level' => 'warn')
      end
    end

    context 'when the proxy comes with a Cloudflare clearance' do
      let(:dou_proxies) do
        [ proxy_mate_row(7, url: 'socks5h://203.0.113.7:1080',
                            cloudflare: { cookie: 'cf_clearance=tok', user_agent: 'Mozilla/5.0 Firefox/147.0', impersonate: 'firefox147' }) ]
      end

      it 'drives every request through that proxy with the clearance' do
        allow(ApplyMate::Client::ImpersonateHttp).to receive(:new).and_call_original

        operation.call

        clearance = ApplyMate::Client::ProxyMate::Clearance.new(cookie: 'cf_clearance=tok', user_agent: 'Mozilla/5.0 Firefox/147.0',
                                                                impersonate: 'firefox147')
        expect(ApplyMate::Client::ImpersonateHttp).to have_received(:new)
          .with(hash_including(proxy: 'socks5h://203.0.113.7:1080', clearance: clearance)).at_least(:once)
        expect(ApplyMate::Client::ImpersonateHttp).not_to have_received(:new).with(hash_including(clearance: nil))
        expect(source_dou.vacancies.count).to eq(20)
      end
    end

    it 'reports the description pass to Grafana' do
      events = capture_logged_events

      operation.call

      expect(events.find { |e| e['event'] == 'vacancy_sync_descriptions_finished' }).to include(
        'source' => 'Dou', 'result' => 'ok', 'missing' => 20, 'fetched' => 20, 'gave_up' => 0,
        'requests' => 20, 'empty_responses' => 0
      )
    end

    it 'visits each vacancy page to fetch descriptions' do
      fetch_count = 0
      allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get)
        .with(a_string_including('jobs.dou.ua/companies/')) do |_instance, _url|
          fetch_count += 1
          @dou_detail_index ||= 0
          @dou_detail_index += 1
          @dou_detail_index = 1 if @dou_detail_index > 20
          ApplyMate::Client::ImpersonateHttp::Response.new(file_fixture("dou/list/details/#{@dou_detail_index}.html").read, {}, 200)
        end

      operation.call
      expect(fetch_count).to eq(20)
      expect(source_dou.vacancies.pluck(:description).compact.size).to eq(20)
    end

    it 'fetches descriptions even when vacancies are streamed in several batches' do
      stub_const('Vacancy::Operation::SyncVacancies::VACANCY_FETCH_BATCH', 5)
      operation.call
      expect(source_dou.vacancies.pluck(:description).compact.size).to eq(20)
    end
  end

  describe 'Global behavior' do
    let!(:source_djinni) { create(:source, name: 'Djinni', base_url: 'https://djinni.co', scraper: 'ApplyMate::Scraper::Djinni') }
    let(:djinni_html_content) { file_fixture('djinni/list/vacancies_page.html').read }

    before do
      allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get).and_return(ApplyMate::Client::ImpersonateHttp::Response.new('<html></html>', {}, 200, ''))
      allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get).with(a_string_including('djinni.co')) do |_instance, url|
        if url.include?('page=1') || !url.include?('page=')
          ApplyMate::Client::ImpersonateHttp::Response.new(djinni_html_content, {}, 200, url)
        else
          ApplyMate::Client::ImpersonateHttp::Response.new('', {}, 200, ApplyMate::Scraper::Djinni::JOB_LIST_URL)
        end
      end
    end

    it 'triggers Elasticsearch indexing for each batch' do
      without_partial_double_verification do
        expect_any_instance_of(ActiveRecord::Relation).to receive(:import).at_least(:once)
      end
      described_class.call
    end
  end

  describe 'RAM buffer flushing' do
    let!(:source_djinni) { create(:source, name: 'Djinni', base_url: 'https://djinni.co', scraper: 'ApplyMate::Scraper::Djinni') }
    let(:djinni_html_content) { file_fixture('djinni/list/vacancies_page.html').read }
    let(:operation) { described_class.new(sources: [ source_djinni ]) }

    before do
      # Every page returns the same 15-vacancy listing, so each scraped page adds to
      # the buffer and (with a tiny limit) triggers a mid-run flush instead of waiting
      # for the final flush.
      allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get)
        .with(a_string_including('djinni.co')) do |_instance, url|
          ApplyMate::Client::ImpersonateHttp::Response.new(djinni_html_content, {}, 200, url)
        end
    end

    it 'flushes mid-run on the buffer limit and persists every vacancy exactly once' do
      stub_const('Vacancy::Operation::SyncVacancies::VACANCY_BUFFER_LIMIT', 5)

      flush_count = 0
      allow(Vacancy).to receive(:upsert_all).and_wrap_original do |orig, *args, **kwargs|
        flush_count += 1
        orig.call(*args, **kwargs)
      end

      operation.call

      # MAX_PAGES is stubbed to 3 and every page has data, so the limit is crossed on
      # each page → several mid-run flushes (not a single final flush).
      expect(flush_count).to be > 1
      # Same external_ids upserted repeatedly — idempotent, and no appends lost across
      # the buffer swap.
      expect(source_djinni.vacancies.count).to eq(15)
    end
  end

  describe 'when a source has no live proxy at the start' do
    let!(:source_djinni) { create(:source, name: 'Djinni', base_url: 'https://djinni.co', scraper: 'ApplyMate::Scraper::Djinni') }
    let!(:source_dou)    { create(:source, name: 'Dou', base_url: 'https://jobs.dou.ua', scraper: 'ApplyMate::Scraper::Dou') }

    before do
      allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get).with(a_string_including('djinni.co')) do |_instance, url|
        if url.include?('page=1') || !url.include?('page=')
          ApplyMate::Client::ImpersonateHttp::Response.new(file_fixture('djinni/list/vacancies_page.html').read, {}, 200, url)
        else
          ApplyMate::Client::ImpersonateHttp::Response.new('', {}, 200, ApplyMate::Scraper::Djinni::JOB_LIST_URL)
        end
      end
    end

    it 'skips that source, syncs the others and reports the run as partial' do
      stub_proxy_mate('dou', [])
      events = capture_logged_events

      described_class.new(sources: [ source_djinni, source_dou ]).call

      expect(source_djinni.vacancies.count).to eq(15)
      expect(events.select { |e| e['event'] == 'vacancy_sync_proxy_pool_ready' }).to contain_exactly(
        a_hash_including('source' => 'Djinni', 'level' => 'info'),
        a_hash_including('source' => 'Dou', 'alive' => 0, 'with_clearance' => 0, 'level' => 'warn')
      )
      expect(events.find { |e| e['event'] == 'vacancy_sync_finished' })
        .to include('result' => 'partial', 'sources_ok' => 1, 'sources_failed' => 1, 'level' => 'error')
    end

    it 'raises when no source can run, still reporting the failed run' do
      stub_proxy_mate('djinni', [])
      stub_proxy_mate('dou', [])
      events = capture_logged_events

      expect { described_class.new(sources: [ source_djinni, source_dou ]).call }
        .to raise_error(described_class::NoProxiesError)
      expect(events.find { |e| e['event'] == 'vacancy_sync_finished' }).to include(
        'result' => 'failed', 'sources_ok' => 0, 'sources_failed' => 2,
        'error_class' => described_class::NoProxiesError.name
      )
    end
  end

  describe 'when ProxyMate cannot hand out proxies' do
    let!(:source_djinni) { create(:source, name: 'Djinni', base_url: 'https://djinni.co', scraper: 'ApplyMate::Scraper::Djinni') }
    let(:operation) { described_class.new(sources: [ source_djinni ]) }

    def pool_event(events)
      events.find { |e| e['event'] == 'vacancy_sync_proxy_pool_ready' }
    end

    it 'reports a rejected API key on the source and fails the run without scraping' do
      stub_request(:post, proxy_mate_batch_url('djinni')).to_return(
        status: 401, headers: { 'Content-Type' => 'application/json' },
        body: { error: 'unauthorized', message: 'Missing or invalid API key (Authorization: Bearer <key>)' }.to_json
      )
      events = capture_logged_events

      expect { operation.call }.to raise_error(described_class::NoProxiesError)
      expect(pool_event(events)).to include(
        'source' => 'Djinni', 'alive' => 0, 'level' => 'error',
        'error_class' => ApplyMate::Client::ProxyMate::ResponseError.name,
        'error' => a_string_including('401 unauthorized')
      )
      expect(events.find { |e| e['event'] == 'vacancy_sync_finished' }).to include('result' => 'failed')
      expect(a_request(:get, /djinni\.co/)).not_to have_been_made
    end

    it 'reports an unreachable ProxyMate on the source' do
      stub_request(:post, proxy_mate_batch_url('djinni')).to_timeout
      events = capture_logged_events

      expect { operation.call }.to raise_error(described_class::NoProxiesError)
      expect(pool_event(events)).to include('level' => 'error', 'error_class' => ApplyMate::Client::ProxyMate::RequestError.name)
    end

    it 'reports missing configuration without calling anyone' do
      ENV['PROXY_MATE_URL'] = ''
      events = capture_logged_events

      expect { operation.call }.to raise_error(described_class::NoProxiesError)
      expect(pool_event(events)).to include('level' => 'error', 'error_class' => ApplyMate::Client::ProxyMate::ConfigurationError.name,
                                            'error' => a_string_including('PROXY_MATE_URL'))
      expect(a_request(:post, proxy_mate_batch_url('djinni'))).not_to have_been_made
    end
  end

  describe 'when the only proxy is dead' do
    let!(:source_djinni) { create(:source, name: 'Djinni', base_url: 'https://djinni.co', scraper: 'ApplyMate::Scraper::Djinni') }
    let(:operation) { described_class.new(sources: [ source_djinni ]) }

    before do
      # Every request fails with a proxy-dead status, so the scraper raises DeadProxyError.
      allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get)
        .and_return(ApplyMate::Client::ImpersonateHttp::Response.new('', {}, 503, ''))
    end

    it 'reports the failed source and the failed run to Grafana' do
      events = capture_logged_events

      operation.call

      listing = events.find { |e| e['event'] == 'vacancy_sync_listing_finished' }
      # MAX_EMPTY_ROUNDS rounds, the proxy dying once in each
      expect(listing).to include('result' => 'failed', 'level' => 'error', 'source' => 'Djinni',
                                 'error_class' => described_class::NoProxiesError.name,
                                 'dead_proxies' => 2, 'failed_requests' => 2, 'pages' => 0, 'proxy_rounds' => 2)
      expect(listing).not_to have_key('new_vacancies')
      expect(events.find { |e| e['event'] == 'vacancy_sync_finished' })
        .to include('result' => 'failed', 'level' => 'error', 'sources_ok' => 0, 'sources_failed' => 1)
    end

    it 'drops the proxy, refills in the same session, brings it back for one more round, then stops' do
      events = capture_logged_events

      operation.call

      proxy_session = "applymate-#{events.first['session_id']}-#{source_djinni.id}"
      batches = proxy_mate_bodies(:post, proxy_mate_batch_url('djinni'))
      # seed, then one refill per round that ends it (nothing new, remaining: 0)
      expect(batches.map { |body| body.values_at('limit', 'session_id') })
        .to eq([ [ 1000, proxy_session ], [ 300, proxy_session ], [ 300, proxy_session ] ])
      expect(batches).to all(satisfy { |body| !body.key?('exclude_ids') })
      expect(events.select { |e| e['event'] == 'vacancy_sync_proxy_round_started' })
        .to contain_exactly(a_hash_including('source' => 'Djinni', 'round' => 2, 'proxies' => 1, 'session_id' => events.first['session_id']))
      expect(events.map { |e| e['event'] }).not_to include('vacancy_sync_proxy_refill_failed')
    end

    it 'never reports anything back to ProxyMate' do
      operation.call

      expect(a_request(:any, %r{\A#{Regexp.escape(ProxyMateSupport::URL)}/api/v1/(?!meta\z|sites/djinni/proxies/batch\z)}))
        .not_to have_been_made
    end

    # Termination: an empty pool whose refills keep failing must end the source, not spin.
    it 'stops the source after MAX_REFILL_FAILURES failed refills in a row' do
      stub_request(:post, proxy_mate_batch_url('djinni'))
        .to_return(proxy_mate_response([ proxy_mate_row(1) ]), { status: 503, body: 'Service Unavailable' })
      events = capture_logged_events

      operation.call

      # MAX_REFILL_FAILURES per round, MAX_EMPTY_ROUNDS rounds: the count runs on until a refill works
      failures = events.select { |e| e['event'] == 'vacancy_sync_proxy_refill_failed' }
      expect(failures.map { |e| e['failures'] }).to eq([ 1, 2, 3, 4, 5, 6 ])
      expect(failures.first).to include('source' => 'Djinni', 'alive' => 0, 'level' => 'warn',
                                        'error_class' => ApplyMate::Client::ProxyMate::ResponseError.name)
      expect(events.find { |e| e['event'] == 'vacancy_sync_listing_finished' })
        .to include('result' => 'failed', 'error_class' => described_class::NoProxiesError.name)
    end

    # Unexpected (non-proxy) errors are not successful uses, so the rounds end too.
    it 'stops the source when every request ends in an unexpected error' do
      stub_const('Vacancy::Operation::SyncVacancies::ProxyPool::MAX_USES', 3)
      allow_any_instance_of(ApplyMate::Scraper::Djinni).to receive(:fetch_listing).and_raise(NoMethodError, 'markup changed')
      events = capture_logged_events

      operation.call

      expect(events.find { |e| e['event'] == 'vacancy_sync_listing_finished' }).to include(
        'result' => 'failed', 'error_class' => described_class::NoProxiesError.name, 'proxy_rounds' => 2,
        'requests' => 6, 'dead_proxies' => 0, 'errors' => 'NoMethodError×6 (markup changed)'
      )
    end

    context 'when the refill brings a working proxy' do
      before do
        stub_request(:post, proxy_mate_batch_url('djinni'))
          .to_return(proxy_mate_response([ proxy_mate_row(1) ]), proxy_mate_response([ proxy_mate_row(2) ]), proxy_mate_response([]))
        allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get) do |client, url|
          next ApplyMate::Client::ImpersonateHttp::Response.new('', {}, 503, url) if client.instance_variable_get(:@proxy).include?('10.0.0.2')
          next ApplyMate::Client::ImpersonateHttp::Response.new(file_fixture('djinni/list/vacancies_page.html').read, {}, 200, url) if url.include?('page=1')

          ApplyMate::Client::ImpersonateHttp::Response.new('', {}, 200, ApplyMate::Scraper::Djinni::JOB_LIST_URL)
        end
      end

      it 'carries on with the new proxy' do
        operation.call

        expect(source_djinni.vacancies.count).to eq(15)
      end
    end
  end
end
