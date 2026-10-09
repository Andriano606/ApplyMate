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
  let(:landing_html) { '<html><body>Google Forms</body></html>' }

  def call
    described_class.call(apply:, entry_url:, out:)
  end

  before do
    allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call) { |url:| FixtureSite.resolution(url) }
    allow(ApplyMate::Client::ImpersonateHttp::ReadOnly).to receive(:new).and_return(http)
    pages = {
      entry_url => ApplyMate::Client::Response.new('', { 'location' => redirect_to }, 302, nil),
      job_url => ApplyMate::Client::Response.new('<html><body><div id="root"></div></body></html>', {}, 200, nil),
      redirect_to => ApplyMate::Client::Response.new(landing_html, {}, 200, nil)
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
    expect(report[:fields].size).to eq(14)
    expect(report[:fields].pluck('id')).to all(start_with('ashby:'))
    expect(report[:fields].pluck('widget')).to include('text', 'aria_combobox', 'option_group', 'file_input')
    expect(out.string).to include('platform:   ashby', 'schema api: 0 field(s)', "form url:   #{canonical}",
                                  'fields (14):', 'id ', 'ashby:_systemfield_email')
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

    %i[fill type select check uncheck upload].each { |method| expect(session.calls_of(method)).to be_empty }
    # Only the keys that open and close a combobox to read its options (Engine::ReadComboboxOptions), never Enter.
    expect(session.calls_of(:press).map(&:last)).to all(satisfy { |key| Apply::Operation::Engine::ReadComboboxOptions::KEYS.include?(key) })
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

  # The surveyed row is `running` with no job behind it; a Navigator may outlast STALE_AFTER, and a reaped row is
  # auto-resumed into the FULL engine. The beat keeps it alive and stops before the cancelling write.
  it 'heartbeats the running row for the whole survey and stops the ticker before cancelling it' do
    ticker = nil
    shut_down_at_restore = nil
    allow(Apply::Operation::Engine::Heartbeat).to receive(:call).and_wrap_original do |original, **kwargs|
      original.call(**kwargs).tap { |result| ticker = result.model }
    end
    allow(Apply::Operation::Engine::FencedUpdate).to receive(:call).and_wrap_original do |original, **kwargs|
      shut_down_at_restore = ticker.shutdown? if kwargs[:attributes][:state] == :cancelled
      original.call(**kwargs)
    end
    call

    expect(Apply::Operation::Engine::Heartbeat).to have_received(:call).once
    expect(shut_down_at_restore).to be(true)
  end

  it 'beats with the survey run token, so a long survey never looks stale to ReapStale' do
    beat = nil
    allow(Apply::Operation::Engine::Heartbeat).to receive(:call).and_wrap_original do |original, ctx:|
      beat = -> { Apply::Operation::Engine::Heartbeat::Tick.call(ctx:).model }
      original.call(ctx:)
    end
    session.on(:goto) do
      apply.update_columns(heartbeat_at: 10.minutes.ago, updated_at: 10.minutes.ago)
      expect(beat.call).to be(true)
      expect(apply.reload.heartbeat_at).to be > 1.minute.ago
    end
    call

    expect(session.calls_of(:goto)).not_to be_empty
  end

  context 'when the entry URL leads to a site no adapter knows (Generic: the AI Navigator)' do
    let(:redirect_to) { 'https://acme.example/careers/1' }
    let(:landing_html) { '<html><body><h1>Senior Ruby developer</h1><button>Apply now</button></body></html>' }
    let(:form_css) { 'body > main > form' }
    let(:job_page) do
      build_snapshot(frames: [ { url: redirect_to } ], elements: [ snapshot_element(role: 'button', name: 'Apply now') ])
    end
    let(:form_page) do
      build_snapshot(frames: [ { url: redirect_to } ], elements: [
        snapshot_element(role: 'button', name: 'Apply now', expanded: true),
        *[ [ 'Full name', 'text' ], [ 'Email', 'email' ], [ 'Phone', 'tel' ] ].each_with_index.map { |(name, type), index|
          snapshot_element(name:, type:, css: "#{form_css} > input:nth-of-type(#{index + 1})", regions: [ form_css ])
        },
        snapshot_element(role: 'button', name: 'Send application', submit_like: true, css: "#{form_css} > button",
                         regions: [ form_css ])
      ])
    end
    let(:session) { FakeSession.new(html: '', final_url: redirect_to, snapshot: job_page) }
    let(:answers) do
      [ { status: 'continue', reason: 'open the form', form: nil, give_up_code: nil,
          actions: [ { type: 'click', ref: 'f0:e0', key: nil, index: nil, max_ms: nil } ] },
        { status: 'form_reached', reason: 'name, email, phone', actions: [], give_up_code: nil,
          form: { frame: 'f0', scope_ref: 'f0:e1', field_refs: %w[f0:e1 f0:e2 f0:e3], submit_ref: 'f0:e4', advance_ref: nil } } ]
    end

    before do
      allow(session).to receive(:current_url).and_return('about:blank', redirect_to)
      session.on(:click) { session.show(form_page) }
      stub_request(:post, %r{generativelanguage\.googleapis\.com.*generateContent})
        .to_return(*answers.map { |answer| gemini_json_response(answer.to_json) })
    end

    it 'navigates to the form, reports the AI calls and the navigator and reads the fields from the DOM' do
      report = call.model

      expect(report).to include(platform: 'generic', form_reached: true, ai_calls: 2, navigator_actions: 1,
                                form_url: redirect_to, form_frame: 'top')
      expect(report[:navigation].pluck('op')).to eq(%w[goto click wait_for])
      expect(report[:fields].pluck('label')).to eq([ 'Full name', 'Email', 'Phone' ])
      expect(out.string).to include('navigator:  1 action(s), form reached yes', 'ai calls:   2', 'fields (3):')
    end

    it 'only moves through pages: never types, selects, checks, uploads, presses or submits' do
      call

      %i[fill type select set_checked upload press trial_click].each { |method| expect(session.calls_of(method)).to be_empty }
      expect(session.calls_of(:click).map(&:first)).to eq([ job_page.elements.first['target'] ])
      expect(Apply::Operation::Engine::ClaimSubmit).not_to have_received(:call)
      expect(apply.reload).to have_attributes(state: 'cancelled', navigation: nil, fields: nil)
    end

    it 'reports the give-up as the halt with form reached no' do
      stub_request(:post, %r{generativelanguage\.googleapis\.com.*generateContent}).to_return(gemini_json_response(
        { status: 'give_up', reason: 'sign-in first', actions: [], form: nil, give_up_code: 'login_required' }.to_json
      ))

      report = call.model

      expect(report).to include(halt: include(code: :login_required), form_reached: false, ai_calls: 1, fields: [])
      expect(out.string).to include('navigator:  0 action(s), form reached no', 'halt:       login_required')
    end
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
