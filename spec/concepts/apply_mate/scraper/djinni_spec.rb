# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Scraper::Djinni do
  let(:source)  { build(:source, name: 'Djinni', base_url: 'https://djinni.co', scraper: described_class.name) }
  let(:client)  { instance_double(ApplyMate::Client::AsyncHttp) }
  let(:scraper) { described_class.new(source, client) }

  it_behaves_like 'a scraper with a session cookie', 'sessionid'

  describe '#fetch_applyble' do
    let(:page_html) { '<button class="js-inbox-toggle-reply-form">Відгукнутися</button>' }

    before { allow(client).to receive(:get).and_return(Struct.new(:status, :body).new(200, page_html)) }

    it 'fetches the vacancy page with the session cookie' do
      expect(scraper.fetch_applyble('https://djinni.co/jobs/1/', session_id: 'abc')).to be(true)
      expect(client).to have_received(:get).with('https://djinni.co/jobs/1/', headers: { 'Cookie' => 'sessionid=abc' })
    end
  end
end
