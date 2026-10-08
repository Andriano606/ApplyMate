# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::CollectHttpEvidence do
  subject(:evidence) { described_class.call(entry_url:, http:).model }

  let(:http) { ApplyMate::Client::ImpersonateHttp.new }
  let(:entry_url) { 'https://dou.ua/goto/vacancy/?id=375494' }
  let(:preply) { 'https://preply.com/en/careers/apply?ashby_jid=20587adf-cf02-473e-8a80-7b009711a2cf' }
  let(:page_html) do
    <<~HTML
      <html><head>
        <script src="https://jobs.ashbyhq.com/preply/embed?version=2"></script>
        <script src="/assets/app.js"></script>
      </head><body><iframe src="//www.youtube.com/embed/x"></iframe></body></html>
    HTML
  end
  let(:responses) do
    {
      entry_url => redirect(preply),
      preply => ApplyMate::Client::Response.new(page_html, {}, 200, preply)
    }
  end

  def redirect(location, status: 302)
    ApplyMate::Client::Response.new('', { 'location' => location }, status, nil)
  end

  before do
    allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call) { |url:| FixtureSite.resolution(url) }
    allow(http).to receive(:get) { |url, **| responses.fetch(url) }
  end

  it 'walks the redirect chain and keeps only the final URL as current' do
    expect(evidence.hops).to eq([ entry_url, preply ])
    expect(evidence.current_urls).to eq([ preply ])
  end

  it 'sends every hop through the address guard, pinned and without curl following redirects' do
    evidence

    [ entry_url, preply ].each do |url|
      expect(ApplyMate::Net::Operation::ResolvePublicAddress).to have_received(:call).with(url:)
      expect(http).to have_received(:get).with(url, headers: {}, follow_redirects: false, resolve: anything)
    end
  end

  it 'scans the final page for absolute script and iframe sources' do
    expect(evidence.script_srcs).to eq([ 'https://jobs.ashbyhq.com/preply/embed?version=2', 'https://preply.com/assets/app.js' ])
    expect(evidence.iframe_srcs).to eq([ 'https://www.youtube.com/embed/x' ])
  end

  it 'resolves a relative Location against the previous URL' do
    responses[entry_url] = redirect('/careers/apply?x=1', status: 301)
    responses['https://dou.ua/careers/apply?x=1'] = ApplyMate::Client::Response.new('', {}, 404, nil)

    expect(evidence.current_urls).to eq([ 'https://dou.ua/careers/apply?x=1' ])
  end

  it 'keeps the URLs but no HTML evidence for a Cloudflare interstitial' do
    responses[preply] = ApplyMate::Client::Response.new(
      '<title>Just a moment...</title><script src="https://cdn.test/cf.js"></script>', {}, 403, preply
    )

    expect(evidence.current_urls).to eq([ preply ])
    expect(evidence.script_srcs).to be_empty
  end

  it 'halts with no_application_path after MAX_HOPS redirects (a loop never ends on its own)' do
    responses[entry_url] = redirect('https://a.test/1')
    (1..described_class::MAX_HOPS + 1).each { |i| responses["https://a.test/#{i}"] = redirect("https://a.test/#{i + 1}") }

    expect { evidence }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
      expect(halt).to have_attributes(code: :no_application_path, detail: 'redirect loop')
    }
    expect(http).to have_received(:get).exactly(described_class::MAX_HOPS + 1).times
  end

  it 'follows exactly MAX_HOPS redirects' do
    responses[entry_url] = redirect('https://a.test/1')
    (1...described_class::MAX_HOPS).each { |i| responses["https://a.test/#{i}"] = redirect("https://a.test/#{i + 1}") }
    responses["https://a.test/#{described_class::MAX_HOPS}"] = ApplyMate::Client::Response.new('', {}, 200, nil)

    expect(evidence.hops.size).to eq(described_class::MAX_HOPS + 1)
  end

  it 'ends the walk at a hop curl cannot fetch (no HTML evidence) and says why' do
    allow(http).to receive(:get).with(preply, any_args)
                                .and_raise(ApplyMate::Client::ImpersonateHttp::RequestError, 'exit 28: timed out')

    result = described_class.call(entry_url:, http:)

    expect(result.model).to have_attributes(hops: [ entry_url, preply ], current_urls: [ preply ], script_srcs: [])
    expect(result[:fetch_error]).to eq('RequestError: exit 28: timed out')
  end

  it 'lets a private hop raise UnsafeUrlError before it is requested' do
    responses[entry_url] = redirect('http://192.168.1.1/admin')
    allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call).with(url: 'http://192.168.1.1/admin')
                                                                    .and_call_original

    expect { evidence }.to raise_error(ApplyMate::Net::UnsafeUrlError)
    expect(http).not_to have_received(:get).with('http://192.168.1.1/admin', any_args)
  end
end
