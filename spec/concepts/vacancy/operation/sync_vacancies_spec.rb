# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Vacancy::Operation::SyncVacancies, type: :operation do
  before do
    # Stub Elasticsearch import on Vacancy relation
    allow_any_instance_of(ActiveRecord::Relation).to receive(:import)
    # Also stub close method as it is called in ensure block
    allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:close)
  end

  describe 'Djinni source' do
    let!(:source_djinni) { create(:source, name: 'Djinni', scraper: 'ApplyMate::Scraper::Djinni') }
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
  end

  describe 'DOU source' do
    let!(:source_dou) { create(:source, name: 'Dou', scraper: 'ApplyMate::Scraper::Dou') }
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

      # Stub DOU XHR listing
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:post_xhr).with(
        ApplyMate::Scraper::Dou::XHR_URL, anything, anything
      ).and_return({ html: dou_html_content, last: true }.to_json)

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
      expect(vacancy.company_icon_url).to eq('https://s.dou.ua/CACHE/images/img/static/companies/Logo_GB/2f21f669737958c2057f91cf73be5d75.png')

      # Verify that the description was scraped correctly from the detail fixture
      # Taking a significant block from the first 20 lines for comparison
      expect(vacancy.description).to include('8 травня 2026')
      expect(vacancy.description).to include('Senior Customer Success Manager')
      expect(vacancy.description).to include('GrowthBand runs done-for-you lead generation for mid-market B2B companies')
      expect(vacancy.description).to include('You own the client relationship completely')
    end

    it 'visits each vacancy page to fetch descriptions' do
      expect_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:fetch_body)
        .with(a_string_including('jobs.dou.ua/companies/'))
        .exactly(20).times
        .and_call_original

      operation.call
      expect(source_dou.vacancies.pluck(:description).compact.size).to eq(20)
    end
  end

  describe 'Global behavior' do
    let!(:source_djinni) { create(:source, name: 'Djinni', scraper: 'ApplyMate::Scraper::Djinni') }
    let(:djinni_html_content) { file_fixture('djinni/list/vacancies_page.html').read }

    before do
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:fetch_body).and_return('<html></html>')
      allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:fetch_body).with(a_string_including('djinni.co')).and_return(djinni_html_content)
    end

    it 'triggers Elasticsearch indexing for each batch' do
      expect_any_instance_of(ActiveRecord::Relation).to receive(:import).at_least(:once)
      described_class.call
    end

    it 'raises TerminationError when solid_queue_terminating is set' do
      Thread.main[:solid_queue_terminating] = true
      expect {
        described_class.call
      }.to raise_error(ApplyMate::Scraper::Base::TerminationError)
    ensure
      Thread.main[:solid_queue_terminating] = false
    end
  end
end
