# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Vacancy::Operation::SyncVacancies, type: :operation do
  # Proxy must be committed (not inside a per-example transaction) so that
  # Async fibers, which check out a separate DB connection, can see it.
  before(:all) do
    @proxy = Proxy.create!(host: '127.0.0.1', port: 8080, protocol: 'http')
  end

  after(:all) do
    @proxy&.destroy
  end

  before do
    # Reduce async concurrency so tests finish instantly instead of spinning
    # through thousands of fiber iterations with mocked HTTP responses.
    stub_const('Vacancy::Operation::SyncVacancies::WORKERS_PER_SOURCE', 1)
    stub_const('Vacancy::Operation::SyncVacancies::DESCRIPTION_WORKERS', 1)
    stub_const('Vacancy::Operation::SyncVacancies::MAX_PAGES', 3)
    # Skip live proxy pre-flight validation in tests — the HTTP client is stubbed
    # per-source, so a real probe to the validation URL would fail/poison the pool.
    stub_const('Vacancy::Operation::SyncVacancies::VALIDATE_PROVEN_ON_START', false)
    stub_const('Vacancy::Operation::SyncVacancies::LAST_PAGE_CONFIRMATIONS', 1)
    # Disable the in-memory proxy cooldown so the handful of test proxies can be
    # reused immediately instead of resting for 5s between requests.
    allow(ApplyMate::Scraper::Dou).to receive(:burst_cooldown).and_return(0)
    allow(ApplyMate::Scraper::Djinni).to receive(:burst_cooldown).and_return(0)
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
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get).with(a_string_including('djinni.co')) do |_instance, url|
        if url.include?('page=1') || !url.include?('page=')
          ApplyMate::Client::AsyncHttp::Response.new(djinni_html_content, {}, 200, url)
        else
          ApplyMate::Client::AsyncHttp::Response.new('', {}, 200, ApplyMate::Scraper::Djinni::JOB_LIST_URL)
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
        .to include('session_id' => session, 'source' => 'Djinni', 'checked' => 1, 'alive' => 1)
      expect(by_name.fetch('vacancy_sync_listing_finished')).to include(
        'session_id' => session, 'source' => 'Djinni', 'result' => 'ok', 'level' => 'info',
        'pages' => 1, 'vacancies' => 15, 'new_vacancies' => 14, 'stale_deleted' => 1, 'vacancies_total' => 15,
        'dead_proxies' => 0, 'failed_requests' => 0, 'errors' => nil
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
      # Committed outside the per-example transaction so Async fibers see them.
      before(:all) do
        @proxy2 = Proxy.create!(host: '127.0.0.2', port: 8080, protocol: 'http')
      end

      after(:all) do
        @proxy2&.destroy
      end

      before do
        stub_const('Vacancy::Operation::SyncVacancies::WORKERS_PER_SOURCE', 2)

        @page1_calls = 0

        # First request to page 1 returns a blocked page (200, no job nodes, NO redirect) —
        # the scraper treats that as a dead proxy and raises, so the page is retried on
        # another proxy and page 1 is fetched twice. Page 3+ redirects to /jobs/ (the real
        # last page). sleep(0.05) yields so fiber 2 can scrape page 2 meanwhile.
        allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get)
          .with(a_string_including('djinni.co')) do |_instance, url|
            if url.include?('page=1') || !url.include?('page=')
              sleep(0.05)
              @page1_calls += 1
              body = @page1_calls == 1 ? '<html><body></body></html>' : djinni_html_content
              ApplyMate::Client::AsyncHttp::Response.new(body, {}, 200, url)
            elsif url.include?('page=2')
              ApplyMate::Client::AsyncHttp::Response.new(djinni_html_content, {}, 200, url)
            else
              ApplyMate::Client::AsyncHttp::Response.new('', {}, 200, ApplyMate::Scraper::Djinni::JOB_LIST_URL)
            end
          end
      end

      it 'retries the blocked page instead of treating it as the last page' do
        operation.call
        expect(@page1_calls).to eq(2)
      end
    end
  end

  describe 'DOU source' do
    let!(:source_dou) { create(:source, name: 'Dou', base_url: 'https://jobs.dou.ua', scraper: 'ApplyMate::Scraper::Dou') }
    let(:dou_html_content) { file_fixture('dou/list/vacancies_page.html').read }
    let(:operation) { described_class.new(sources: [ source_dou ]) }

    before do
      # Dou is behind Cloudflare, so the pipeline drives it through ImpersonateHttp
      # (Scraper::Dou.http_client_class). Stub that client, not AsyncHttp.
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
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get).and_return(ApplyMate::Client::AsyncHttp::Response.new('<html></html>', {}, 200, ''))
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get).with(a_string_including('djinni.co')) do |_instance, url|
        if url.include?('page=1') || !url.include?('page=')
          ApplyMate::Client::AsyncHttp::Response.new(djinni_html_content, {}, 200, url)
        else
          ApplyMate::Client::AsyncHttp::Response.new('', {}, 200, ApplyMate::Scraper::Djinni::JOB_LIST_URL)
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
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get)
        .with(a_string_including('djinni.co')) do |_instance, url|
          ApplyMate::Client::AsyncHttp::Response.new(djinni_html_content, {}, 200, url)
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
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get).with(a_string_including('djinni.co')) do |_instance, url|
        if url.include?('page=1') || !url.include?('page=')
          ApplyMate::Client::AsyncHttp::Response.new(file_fixture('djinni/list/vacancies_page.html').read, {}, 200, url)
        else
          ApplyMate::Client::AsyncHttp::Response.new('', {}, 200, ApplyMate::Scraper::Djinni::JOB_LIST_URL)
        end
      end
    end

    # Seeds an empty pool for the given sources (as if every probed proxy was dead).
    def without_live_proxies_for(*sources)
      ids = sources.map(&:id)
      allow_any_instance_of(described_class::ProxyPool).to receive(:candidate_proxies).and_wrap_original do |original|
        ids.include?(original.receiver.instance_variable_get(:@source).id) ? [] : original.call
      end
    end

    it 'skips that source, syncs the others and reports the run as partial' do
      without_live_proxies_for(source_dou)
      events = capture_logged_events

      described_class.new(sources: [ source_djinni, source_dou ]).call

      expect(source_djinni.vacancies.count).to eq(15)
      expect(events.select { |e| e['event'] == 'vacancy_sync_proxy_pool_ready' }).to contain_exactly(
        a_hash_including('source' => 'Djinni', 'level' => 'info'),
        a_hash_including('source' => 'Dou', 'alive' => 0, 'checked' => 0, 'level' => 'warn')
      )
      expect(events.find { |e| e['event'] == 'vacancy_sync_finished' })
        .to include('result' => 'partial', 'sources_ok' => 1, 'sources_failed' => 1, 'level' => 'error')
    end

    it 'raises when no source can run, still reporting the failed run' do
      without_live_proxies_for(source_djinni, source_dou)
      events = capture_logged_events

      expect { described_class.new(sources: [ source_djinni, source_dou ]).call }
        .to raise_error(described_class::NoProxiesError)
      expect(events.find { |e| e['event'] == 'vacancy_sync_finished' }).to include(
        'result' => 'failed', 'sources_ok' => 0, 'sources_failed' => 2,
        'error_class' => described_class::NoProxiesError.name
      )
    end
  end

  describe 'when the only proxy is dead' do
    let!(:source_djinni) { create(:source, name: 'Djinni', base_url: 'https://djinni.co', scraper: 'ApplyMate::Scraper::Djinni') }
    let(:operation) { described_class.new(sources: [ source_djinni ]) }

    before do
      # Every request fails with a proxy-dead status, so the scraper raises DeadProxyError.
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get)
        .and_return(ApplyMate::Client::AsyncHttp::Response.new('', {}, 503, ''))
    end

    after do
      # @proxy is committed (shared across examples); clear the per-source stat the
      # run recorded so it doesn't bleed into other examples.
      ProxySourceStat.where(proxy_id: @proxy.id).delete_all
    end

    it 'reports the failed source and the failed run to Grafana' do
      events = capture_logged_events

      operation.call

      listing = events.find { |e| e['event'] == 'vacancy_sync_listing_finished' }
      expect(listing).to include('result' => 'failed', 'level' => 'error', 'source' => 'Djinni',
                                 'error_class' => described_class::NoProxiesError.name,
                                 'dead_proxies' => 1, 'failed_requests' => 1, 'pages' => 0)
      expect(listing).not_to have_key('new_vacancies')
      expect(events.find { |e| e['event'] == 'vacancy_sync_finished' })
        .to include('result' => 'failed', 'level' => 'error', 'sources_ok' => 0, 'sources_failed' => 1)
    end

    it 'records the failure per-source and drops the proxy from rotation' do
      # The per-source NoProxiesError is raised inside the fiber and logged, not
      # propagated to the caller (existing Async behaviour) — assert the side effect.
      operation.call

      stat = ProxySourceStat.find_by(proxy_id: @proxy.id, source_id: source_djinni.id)
      expect(stat).to be_present
      expect(stat.fail_count).to eq(1)
      expect(stat.failed_at).to be_present
    end
  end
end
