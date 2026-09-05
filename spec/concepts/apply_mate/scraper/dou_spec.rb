# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Scraper::Dou do
  let(:source)  { create(:source, name: 'Dou', base_url: 'https://jobs.dou.ua', scraper: described_class.name) }
  let(:client)  { instance_double(ApplyMate::Client::ImpersonateHttp) }
  let(:scraper) { described_class.new(source, client) }

  before { allow(client).to receive(:get).and_return(Struct.new(:status, :body).new(200, page_html)) }

  describe '#fetch_listing' do
    let(:page_html) { '' }
    let(:item_html) { '<li class="l-vacancy"><a class="vt" href="/companies/acme/vacancies/%d/">Dev</a></li>' }
    let(:session)   { Struct.new(:status, :body, :headers).new(200, '', { 'set-cookie' => 'csrftoken=tok;' }) }

    before do
      allow(client).to receive(:get).with(described_class::VACANCIES_URL).and_return(session)
      allow(client).to receive(:post).and_return(Struct.new(:status, :body).new(200, xhr_body))
    end

    # Dou sends `last: true` TOGETHER with the final partial page (37 items at count=5800
    # of 5837). Returning nil on the flag alone dropped that tail on every sync.
    context 'when the last page still carries vacancies' do
      let(:xhr_body) { { html: (item_html % 1) + (item_html % 2), last: true, num: 40 }.to_json }

      it 'returns the vacancies instead of treating the page as empty' do
        expect(scraper.fetch_listing(page: 146).map(&:external_id)).to eq(%w[1 2])
      end
    end

    context 'when the page past the tail is empty and flagged last' do
      let(:xhr_body) { { html: '', last: true, num: 40 }.to_json }

      it 'returns nil to end pagination' do
        expect(scraper.fetch_listing(page: 147)).to be_nil
      end
    end

    context 'when the page is empty but not flagged last' do
      let(:xhr_body) { { html: '', last: false, num: 40 }.to_json }

      it 'raises DeadProxyError so the page is retried on another proxy' do
        expect { scraper.fetch_listing(page: 5) }.to raise_error(described_class::DeadProxyError, /empty listing/)
      end
    end
  end

  describe '#fetch_description' do
    # `sh-info` lives inside `div.l-vacancy` but outside `div.b-typo.vacancy-section`,
    # so which branch picks the node decides whether prepending it duplicates the line.
    let(:info_html) { '<div class="sh-info"><span>Київ</span>, віддалено</div>' }
    let(:body_html) { '<div class="b-typo vacancy-section"><p>Про нас</p><script>track()</script></div>' }

    context 'when the description section is present' do
      let(:page_html) { "<html><body><div class='l-vacancy'>#{info_html}#{body_html}</div></body></html>" }

      it 'prepends the info line once and keeps the employer markup' do
        html = scraper.fetch_description('https://jobs.dou.ua/companies/acme/vacancies/1/')

        expect(html.scan('Київ').size).to eq(1)
        expect(html).to start_with('<p>Київ, віддалено</p>')
        expect(html).to include('<p>Про нас</p>')
        expect(html).not_to include('<script')
      end

      it 'drops presentation attributes that the renderer would strip anyway' do
        allow(client).to receive(:get).and_return(
          Struct.new(:status, :body).new(200, "<div class='b-typo vacancy-section'><p class='b-a' style='color:red' data-id='7' onclick='x()'>Про нас</p></div>")
        )

        expect(scraper.fetch_description('https://jobs.dou.ua/x/')).to eq('<p>Про нас</p>')
      end
    end

    context 'when the description section is missing and the page wrapper is the fallback' do
      let(:page_html) { "<html><body><div class='l-vacancy'>#{info_html}<p>Про нас</p></div></body></html>" }

      it 'does not repeat the info line that the wrapper already contains' do
        html = scraper.fetch_description('https://jobs.dou.ua/companies/acme/vacancies/1/')

        expect(html.scan('Київ').size).to eq(1)
        expect(html).to include('<p>Про нас</p>')
      end
    end

    context 'when neither node is present' do
      let(:page_html) { '<html><body><p>404</p></body></html>' }

      it 'returns nil so the vacancy is retried instead of stored empty' do
        expect(scraper.fetch_description('https://jobs.dou.ua/x/')).to be_nil
      end
    end
  end
end
