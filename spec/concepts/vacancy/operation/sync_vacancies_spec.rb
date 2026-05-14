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
    stub_const('Vacancy::Operation::SyncVacancies::MAX_PAGES', 3)
    stub_const('Vacancy::Operation::SyncVacancies::LAST_PAGE_CONFIRMATIONS', 1)
    # Prevent the proxy from leaving ready_for_use after first use
    allow_any_instance_of(Proxy).to receive(:mark_used!)
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
      # Stub the HTTP client to return the Djinni fixture
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:fetch_body).with(a_string_including('djinni.co')) do |_instance, url|
        if url.include?('page=1') || !url.include?('page=')
          djinni_html_content
        else
          '<html><body></body></html>'
        end
      end
    end

    it 'syncs 15 vacancies' do
      expect {
        operation.call
      }.to change { source_djinni.vacancies.count }.by(15)
    end

    it 'updates existing vacancies' do
      existing_vacancy = create(:vacancy, source: source_djinni, external_id: '823988', title: 'Old Title')
      operation.call
      expect(existing_vacancy.reload.title).to eq('Operator Experience Designer UI/UX')
    end

    it 'removes stale vacancies' do
      stale_vacancy = create(:vacancy, source: source_djinni, external_id: 'stale_id')
      operation.call
      expect(Vacancy.find_by(id: stale_vacancy.id)).to be_nil
    end

    it 'correctly parses all fields' do
      operation.call
      vacancy = source_djinni.vacancies.find_by(external_id: '823990')

      expect(vacancy).to be_present
      expect(vacancy.title).to eq('Copywriter / Script Writer (Web3 / FinTech / Performance Marketing)')
      expect(vacancy.company_name).to eq('DarkSide')
      expect(vacancy.url).to eq('https://djinni.co/jobs/823990-copywriter-script-writer-web3-fintech-perform/')
      expect(vacancy.company_icon_url).to eq('https://p.djinni.co/f6/759465ffbaeb7add22812612b475ed/photo_2025-04-07_16.14.27_400.jpeg')
      expect(vacancy.description).to include('Ми — performance marketing команда')
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

        # sleep(0.05) is an Async-aware yield — the scheduler switches to fiber 2, which
        # scrapes page 2 (scraped_pages.max becomes 2) before fiber 1 returns its empty
        # result. Page 1 is then an inner page (1 <= scraped_pages.max), so the anti-scraping
        # branch is reached instead of the boundary-candidate branch.
        allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:fetch_body)
          .with(a_string_including('djinni.co')) do |_instance, url|
            if url.include?('page=1') || !url.include?('page=')
              sleep(0.05)
              @page1_calls += 1
              @page1_calls == 1 ? '<html><body></body></html>' : djinni_html_content
            elsif url.include?('page=2')
              djinni_html_content
            else
              '<html><body></body></html>'
            end
          end
      end

      it 'retries the page after a higher-numbered page was already scraped' do
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
      # Stub the HTTP client to return sequential detail files for DOU vacancies
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:fetch_body).with(a_string_including('jobs.dou.ua/companies/')) do |_instance, _url|
        @dou_detail_index ||= 0
        @dou_detail_index += 1
        @dou_detail_index = 1 if @dou_detail_index > 20
        file_fixture("dou/list/details/#{@dou_detail_index}.html").read
      end

      # Stub DOU XHR listing: page 1 (count=0) returns vacancies; subsequent pages
      # return empty HTML with last:true so the scraper stops pagination naturally.
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:post_xhr).with(
        ApplyMate::Scraper::Dou::XHR_URL, anything, anything
      ) do |_instance, _url, body|
        count = URI.decode_www_form(body.to_s).to_h['count'].to_i
        count == 0 ? { html: dou_html_content, last: false }.to_json
                   : { html: '', last: true }.to_json
      end

      # Stub DOU session initialization
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get).with(
        ApplyMate::Scraper::Dou::VACANCIES_URL
      ).and_return(double(headers: { 'set-cookie' => 'csrftoken=test_token;' }))
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
      expect(vacancy.description).to include('8 травня 2026')
      expect(vacancy.description).to include('Senior Customer Success Manager')
      expect(vacancy.description).to include('GrowthBand runs done-for-you lead generation for mid-market B2B companies')
      expect(vacancy.description).to include('You own the client relationship completely')
    end

    it 'visits each vacancy page to fetch descriptions' do
      fetch_count = 0
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:fetch_body)
        .with(a_string_including('jobs.dou.ua/companies/')) do |_instance, _url|
          fetch_count += 1
          @dou_detail_index ||= 0
          @dou_detail_index += 1
          @dou_detail_index = 1 if @dou_detail_index > 20
          file_fixture("dou/list/details/#{@dou_detail_index}.html").read
        end

      operation.call
      expect(fetch_count).to eq(20)
      expect(source_dou.vacancies.pluck(:description).compact.size).to eq(20)
    end
  end

  describe 'Global behavior' do
    let!(:source_djinni) { create(:source, name: 'Djinni', base_url: 'https://djinni.co', scraper: 'ApplyMate::Scraper::Djinni') }
    let(:djinni_html_content) { file_fixture('djinni/list/vacancies_page.html').read }

    before do
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:fetch_body).and_return('<html></html>')
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:fetch_body).with(a_string_including('djinni.co')) do |_instance, url|
        if url.include?('page=1') || !url.include?('page=')
          djinni_html_content
        else
          '<html><body></body></html>'
        end
      end
    end

    it 'triggers Elasticsearch indexing for each batch' do
      without_partial_double_verification do
        expect_any_instance_of(ActiveRecord::Relation).to receive(:import).at_least(:once)
      end
      described_class.call
    end

    it 'raises TerminationError when solid_queue_terminating is set' do
      Thread.main.thread_variable_set(:solid_queue_terminating, true)
      expect {
        described_class.call
      }.to raise_error(ApplyMate::Scraper::Base::TerminationError)
    ensure
      Thread.main.thread_variable_set(:solid_queue_terminating, false)
    end
  end
end
