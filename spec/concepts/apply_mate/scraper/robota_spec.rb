require 'rails_helper'

RSpec.describe ApplyMate::Scraper::Robota do
  let(:source)  { create(:source, name: 'Robota', base_url: 'https://robota.ua/', scraper: described_class.name) }
  let(:client)  { instance_double(ApplyMate::Client::ImpersonateHttp) }
  let(:scraper) { described_class.new(source, client) }

  def response(body, status: 200)
    ApplyMate::Client::Response.new(body, {}, status, nil)
  end

  describe '.listing_segments' do
    it 'splits the listing by career level so every slice stays under the search window' do
      expect(described_class.listing_segments).to eq((0..6).to_a)
    end
  end

  describe '.listing_end_reported?' do
    it 'is true — every page carries the segment total' do
      expect(described_class.listing_end_reported?).to be(true)
    end
  end

  describe '#fetch_listing' do
    let(:search) { JSON.parse(file_fixture('robota/search.json').read) }

    before { allow(client).to receive(:post).and_return(response(search.to_json)) }

    it 'maps every document to a vacancy that links to its page on robota.ua' do
      vacancies = scraper.fetch_listing(page: 1, segment: 3)

      expect(vacancies.map(&:external_id)).to eq(%w[10877579 11386442 11418420])
      expect(vacancies.first.to_h).to include(
        source_id: source.id, title: 'Пекар', company_name: 'Пекарня Lu',
        url: 'https://robota.ua/company15999881/vacancy10877579'
      )
    end

    it 'keeps the company logo and drops robota’s “no logo” placeholder' do
      vacancies = scraper.fetch_listing(page: 1, segment: 3)

      expect(vacancies.first.company_icon_url).to be_nil
      expect(vacancies.last.company_icon_url).to eq('https://logo-frankfurt.cf-rabota.com.ua/7973901_20260305174434.png')
    end

    it 'leaves the description to the vacancy endpoint' do
      expect(scraper.fetch_listing(page: 1, segment: 3).first.to_h).not_to include(:description, :description_html)
    end

    it 'asks for the segment’s career level and the API’s 0-based page' do
      scraper.fetch_listing(page: 3, segment: 4)

      expect(client).to have_received(:post) do |url, body:, **|
        expect(url).to eq(described_class::SEARCH_URL)
        expect(JSON.parse(body)).to eq('page' => 2, 'count' => described_class::PAGE_SIZE, 'profLevelIds' => [ 4 ])
      end
    end

    context 'when the page is past the segment’s total' do
      let(:search) { { total: 164, documents: [] } }

      it 'returns nil to end the segment' do
        expect(scraper.fetch_listing(page: 3, segment: 6)).to be_nil
      end
    end

    context 'when the page is empty although the total says there is more' do
      let(:search) { { total: 38_318, documents: [] } }

      it 'raises DeadProxyError so the page is retried on another proxy' do
        expect { scraper.fetch_listing(page: 5, segment: 1) }.to raise_error(described_class::DeadProxyError, /empty listing/)
      end
    end

    context 'when the page lies beyond the search window' do
      it 'ends the segment without a request — the API answers nothing there' do
        page = (described_class::MAX_RESULT_WINDOW / described_class::PAGE_SIZE) + 1

        expect(scraper.fetch_listing(page:, segment: 1)).to be_nil
        expect(client).not_to have_received(:post)
      end
    end

    context 'when the segment holds more than the window can reach' do
      let(:search) { JSON.parse(file_fixture('robota/search.json').read).merge('total' => 90_000) }

      it 'raises IncompleteListingError so the run deletes nothing it could not reach' do
        expect { scraper.fetch_listing(page: 1, segment: 1) }.to raise_error(described_class::IncompleteListingError, /90000/)
      end
    end

    context 'when the answer is JSON of another shape' do
      let(:search) { { Message: 'An error has occurred.' } }

      it 'raises UnexpectedResponseError instead of reading it as an empty page' do
        expect { scraper.fetch_listing(page: 1, segment: 1) }.to raise_error(described_class::UnexpectedResponseError)
      end
    end

    context 'when robota answers with a server error' do
      before { allow(client).to receive(:post).and_return(response('{"Message":"An error has occurred."}', status: 500)) }

      it 'raises UnexpectedResponseError — robota’s fault, not the proxy’s' do
        expect { scraper.fetch_listing(page: 1, segment: 1) }.to raise_error(described_class::UnexpectedResponseError, /500/)
      end
    end

    context 'when Cloudflare answers with its challenge page' do
      before { allow(client).to receive(:post).and_return(response('<html>Just a moment...</html>', status: 403)) }

      it 'raises DeadProxyError' do
        expect { scraper.fetch_listing(page: 1, segment: 1) }.to raise_error(described_class::DeadProxyError, /403/)
      end
    end

    context 'when a 200 carries something other than JSON' do
      before { allow(client).to receive(:post).and_return(response('<html>captcha</html>')) }

      it 'raises DeadProxyError' do
        expect { scraper.fetch_listing(page: 1, segment: 1) }.to raise_error(described_class::DeadProxyError, /non-JSON/)
      end
    end
  end

  describe '#fetch_description' do
    let(:vacancy) { JSON.parse(file_fixture('robota/vacancy.json').read) }
    let(:url)     { 'https://robota.ua/company15999881/vacancy10877579' }

    before { allow(client).to receive(:get).and_return(response(vacancy.to_json)) }

    it 'reads the vacancy endpoint for the id in the page URL' do
      scraper.fetch_description(url)

      expect(client).to have_received(:get).with("#{described_class::VACANCY_URL}?id=10877579", headers: described_class::HEADERS)
    end

    it 'returns the employer’s markup without the document wrapper or inline styles' do
      html = scraper.fetch_description(url)

      expect(html).to include('<span>Пекар у пекарню (м. Голосіївська)</span>')
      expect(html).not_to include('<html', '<head', '<body', 'style=')
    end

    it 'prepends the salary range from the page header' do
      expect(scraper.fetch_description(url)).to start_with('<p>Зарплата: 40 000 – 46 000 ₴</p>')
    end

    context 'when the salary is one figure with a comment' do
      let(:vacancy) { super().merge('salary' => 17_000, 'salaryFrom' => 0, 'salaryTo' => 0, 'salaryComment' => 'на руки') }

      it 'shows the figure and the comment' do
        expect(scraper.fetch_description(url)).to start_with('<p>Зарплата: 17 000 ₴ · на руки</p>')
      end
    end

    context 'when no salary is given' do
      let(:vacancy) { super().merge('salary' => 0, 'salaryFrom' => 0, 'salaryTo' => 0) }

      it 'starts with the description itself' do
        expect(scraper.fetch_description(url)).to start_with('<p><span>Пекар у пекарню')
      end
    end

    context 'when the description is empty' do
      let(:vacancy) { super().merge('description' => '<html><head></head><body></body></html>') }

      it 'returns nil so the next run retries instead of storing an empty description' do
        expect(scraper.fetch_description(url)).to be_nil
      end
    end

    context 'when the vacancy has been closed since the listing' do
      before { allow(client).to receive(:get).and_return(response('', status: 404)) }

      it 'returns nil' do
        expect(scraper.fetch_description(url)).to be_nil
      end
    end

    context 'when Cloudflare throttles the proxy' do
      before { allow(client).to receive(:get).and_return(response('<html>Just a moment...</html>', status: 403)) }

      it 'raises DeadProxyError so the vacancy is retried on another proxy' do
        expect { scraper.fetch_description(url) }.to raise_error(described_class::DeadProxyError)
      end
    end
  end
end
