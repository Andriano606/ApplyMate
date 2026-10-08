# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::SmokeSurvey do
  let(:apply) { create(:apply) }
  let(:jid) { '20587adf-cf02-473e-8a80-7b009711a2cf' }
  let(:entry_url) { 'https://dou.ua/goto/vacancy/?id=375494' }
  let(:job_url) { "https://jobs.ashbyhq.com/preply/#{jid}" }
  let(:canonical) { "#{job_url}/application" }
  let(:redirect_to) { job_url }
  let(:out) { StringIO.new }
  # The production client of the survey (ReadOnly); only its GETs are stubbed, so its real POST refusal runs.
  let(:http) { ApplyMate::Client::ImpersonateHttp::ReadOnly.new }
  # The production Snapshot of the fixture's Ashby application page (see build_field_inventory_spec.rb).
  let(:snapshot) do
    raw = JSON.parse(file_fixture('apply_engine/ashby/application_frames.json').read).map { |frame| frame.transform_keys(&:to_sym) }
    driver = instance_double(ApplyMate::Client::Browser::Driver::Playwright, evaluate_all_frames: raw)
    regions = [ '#form[role="tabpanel"]', '.ashby-application-form-autofill-input-root' ]
    ApplyMate::Client::Browser::Operation::SnapshotAll.call(driver:, regions:).model
  end
  let(:session) { FakeSession.new(html: '', final_url: canonical, snapshot:) }

  def call
    described_class.call(apply:, entry_url:, out:)
  end

  before do
    allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call) { |url:| FixtureSite.resolution(url) }
    allow(ApplyMate::Client::ImpersonateHttp::ReadOnly).to receive(:new).and_return(http)
    pages = {
      entry_url => ApplyMate::Client::Response.new('', { 'location' => redirect_to }, 302, nil),
      job_url => ApplyMate::Client::Response.new('<html><body><div id="root"></div></body></html>', {}, 200, nil),
      redirect_to => ApplyMate::Client::Response.new('<html><body>Google Forms</body></html>', {}, 200, nil)
    }
    allow(http).to receive(:get) { |url, **| pages.fetch(url) }
    allow(Open3).to receive(:capture3)
    allow(session).to receive(:current_url).and_return('about:blank', canonical)
    stub_browser_session(session)
    allow(Apply::Operation::Engine::ClaimSubmit).to receive(:call)
  end

  it 'detects the platform, reaches the form in one survey lease and prints the fields read from the DOM' do
    report = call.model

    expect(report).to include(platform: 'ashby', captures: { 'slug' => 'preply', 'jid' => jid }, schema_api: 0,
                              canonical_form_url: canonical, form_url: canonical, form_frame: 'top',
                              navigation: [ { 'op' => 'unwrap', 'url_template' => '{canonical_form_url}' } ])
    expect(report).not_to have_key(:halt)
    expect(report[:fields].size).to eq(15)
    expect(report[:fields].pluck('id')).to all(start_with('ashby:'))
    expect(report[:fields].pluck('widget')).to include('text', 'aria_combobox', 'option_group', 'file_input')
    expect(out.string).to include('platform:   ashby', 'schema api: 0 field(s)', "form url:   #{canonical}",
                                  'fields (15):', 'id ', 'ashby:_systemfield_email')
    expect(session.open_options).to contain_exactly(include(humanize: false, identity: apply.hashid))
    expect(session.calls_of(:goto)).to eq([ [ canonical ] ])
  end

  it 'never POSTs to the ATS itself: the schema read is refused before curl and traced, the DOM is read instead' do
    report = call.model

    expect(Open3).not_to have_received(:capture3)
    expect(report[:trace]).to include('schema_unavailable')
  end

  it 'never fills, answers or submits and ends the apply cancelled with its engine columns restored' do
    call

    %i[fill type select check uncheck upload press].each { |method| expect(session.calls_of(method)).to be_empty }
    expect(Apply::Operation::Engine::ClaimSubmit).not_to have_received(:call)
    expect(apply.reload).to have_attributes(state: 'cancelled', stage: nil, platform: nil, platform_match: nil,
                                            apply_key: nil, entry_url: nil, landing_url: nil, fields: nil, form_url: nil, answers: nil)
    expect(apply.apply_steps).to be_empty
  end

  # A queued row is IN_PROGRESS: ReapStale would auto-resume it (or Create's pending job would run it) and the full
  # engine would submit a real application.
  it 'leaves nothing runnable: no reaper pick-up, no late job start, the survey run fenced' do
    run_token = nil
    allow(Apply::Operation::Engine::FencedUpdate).to receive(:call).and_wrap_original do |original, **kwargs|
      run_token ||= kwargs[:ctx].run_token
      original.call(**kwargs)
    end
    call

    apply.reload
    expect(Apply::IN_PROGRESS_STATES).not_to include(apply.state)
    expect(apply.run_token).not_to eq(run_token)
    expect { Apply::Operation::Engine::StartContext.call(apply:) }.to raise_error(Apply::Operation::Engine::NotStartable)
  end

  context 'when the entry URL redirects to a Google Form' do
    let(:redirect_to) { 'https://docs.google.com/forms/d/e/1FAIpQLSf-test/viewform' }

    it 'reports the gate that fired, opens no lease and ends the apply cancelled' do
      report = call.model

      expect(report[:halt]).to eq(code: :manual_apply_required, detail: :google_forms)
      expect(out.string).to include('halt:       manual_apply_required (google_forms)', 'fields (0):')
      expect(session.open_options).to be_empty
      expect(apply.reload).to have_attributes(state: 'cancelled', platform: nil)
    end
  end
end
