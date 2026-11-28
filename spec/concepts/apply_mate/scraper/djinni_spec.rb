# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Scraper::Djinni do
  let(:source)  { create(:source, name: 'Djinni', base_url: 'https://djinni.co', scraper: described_class.name) }
  let(:client)  { instance_double(ApplyMate::Client::ImpersonateHttp) }
  let(:scraper) { described_class.new(source, client) }
  let(:url)     { "#{described_class::JOB_LIST_URL}?page=3" }

  def respond(body, status: 200, final_url: url)
    allow(client).to receive(:get).with(url).and_return(ApplyMate::Client::ImpersonateHttp::Response.new(body, {}, status, final_url))
  end

  it 'is driven through curl-impersonate, like every source' do
    expect(described_class.http_client_class).to eq(ApplyMate::Client::ImpersonateHttp)
  end

  it 'parses the job list' do
    respond(file_fixture('djinni/list/vacancies_page.html').read)

    expect(scraper.fetch_listing(page: 3).size).to eq(15)
  end

  # curl -L follows Djinni's redirect of an out-of-range page back to /jobs/; final_url is
  # curl's url_effective — the only real last-page signal.
  it 'ends pagination when the page redirected back to the job list' do
    respond('<html>first page</html>', final_url: described_class::JOB_LIST_URL)

    expect(scraper.fetch_listing(page: 3)).to be_nil
  end

  it 'treats a page without jobs as a blocked proxy and says which page it got' do
    respond('<!DOCTYPE html><html><body>Please verify you are human</body></html>')

    expect { scraper.fetch_listing(page: 3) }.to raise_error(described_class::DeadProxyError, 'empty job list (proxy rate-limited)')
  end

  it 'treats an empty 200 (how Djinni answers banned IPs) as a dead proxy' do
    respond('')

    expect { scraper.fetch_listing(page: 3) }.to raise_error(described_class::DeadProxyError, /empty job list/)
  end

  it 'treats 429 as a dead proxy before parsing' do
    respond('Too Many Requests', status: 429)

    expect { scraper.fetch_listing(page: 3) }.to raise_error(described_class::DeadProxyError, 'HTTP 429')
  end

  it 'treats a Cloudflare challenge as a dead proxy' do
    respond('<html><head><title>Just a moment...</title></head></html>', status: 403)

    expect { scraper.fetch_listing(page: 3) }.to raise_error(described_class::DeadProxyError, 'HTTP 403 Cloudflare')
  end

  it 'turns a curl failure into a dead proxy carrying what curl said' do
    allow(client).to receive(:get).and_raise(
      ApplyMate::Client::ImpersonateHttp::RequestError, 'curl-impersonate failed (exit 56): CONNECT tunnel failed, response 403'
    )

    expect { scraper.fetch_listing(page: 3) }.to raise_error(
      described_class::DeadProxyError,
      'transport failure (ApplyMate::Client::ImpersonateHttp::RequestError: curl-impersonate failed (exit 56): CONNECT tunnel failed, response 403)'
    )
  end

  it 'lets a curl binary that cannot start through — it is not the proxy' do
    allow(client).to receive(:get).and_raise(ApplyMate::Client::ImpersonateHttp::BinaryError, 'cannot run')

    expect { scraper.fetch_listing(page: 3) }.to raise_error(ApplyMate::Client::ImpersonateHttp::BinaryError)
  end
end
