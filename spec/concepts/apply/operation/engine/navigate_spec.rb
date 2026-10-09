# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::Navigate do
  subject(:navigate) { described_class.call(ctx:).model }

  let(:job) { 'https://acme.example/jobs/1' }
  let(:apply) { create(:apply, entry_url: job) }
  let(:ctx) { engine_context(apply) }
  let(:gemini) { %r{generativelanguage\.googleapis\.com.*generateContent} }
  let(:form_css) { 'body > main > form' }
  let(:session) { FakeSession.new(html: '', final_url: job, snapshot: job_page) }
  let(:prompts) { [] }

  # f0:e0 About link, f0:e1 the Apply tab, f0:e2 a newsletter e-mail box (one field: not an application form)
  let(:job_page) do
    build_snapshot(frames: [ { url: job, outline: [ 'Senior Ruby developer' ] } ], elements: [
      snapshot_element(role: 'link', name: 'About us', href: '/about'),
      snapshot_element(role: 'tab', name: 'Apply', css: 'body > main > div > button:nth-of-type(2)'),
      snapshot_element(name: 'Newsletter e-mail', type: 'email', css: 'body > aside > form > input',
                       regions: [ 'body > aside > form' ])
    ])
  end
  # f0:e0 the selected Apply tab, f0:e1..e3 name / email / phone, f0:e4 the send button
  let(:form_page) do
    build_snapshot(frames: [ { url: job } ], elements: [
      snapshot_element(role: 'tab', name: 'Apply', selected: true, css: 'body > main > div > button:nth-of-type(2)'),
      snapshot_element(name: 'Full name', css: "#{form_css} > input:nth-of-type(1)", regions: [ form_css ]),
      snapshot_element(name: 'Email', type: 'email', css: "#{form_css} > input:nth-of-type(2)", regions: [ form_css ]),
      snapshot_element(name: 'Phone', type: 'tel', css: "#{form_css} > input:nth-of-type(3)", regions: [ form_css ]),
      snapshot_element(role: 'button', name: 'Submit application', submit_like: true, css: "#{form_css} > button",
                       regions: [ form_css ])
    ])
  end

  def action(type, ref: nil, key: nil, index: nil, max_ms: nil)
    { type:, ref:, key:, index:, max_ms: }
  end

  def continue(*actions)
    { status: 'continue', reason: 'closer to the form', actions:, form: nil, give_up_code: nil }
  end

  def form_reached(scope_ref, field_refs: [], submit_ref: nil)
    { status: 'form_reached', reason: 'the form is visible', actions: [],
      form: { frame: 'f0', scope_ref:, field_refs:, submit_ref:, advance_ref: nil }, give_up_code: nil }
  end

  def give_up(code)
    { status: 'give_up', reason: 'cannot continue', actions: [], form: nil, give_up_code: code }
  end

  # The AI answers in order (the last one repeats); a String is sent as it is (invalid JSON). The prompt texts are
  # collected in `prompts`.
  def ai_answers(*answers)
    responses = answers.map { |answer| gemini_json_response(answer.is_a?(String) ? answer : answer.to_json) }
    stub_request(:post, gemini).to_return do |request|
      body = JSON.parse(request.body)
      prompts << body['contents'].flat_map { |content| content['parts'] }.pluck('text').join("\n")
      responses.size > 1 ? responses.shift : responses.first
    end
  end

  def halt_of
    navigate
  rescue Apply::Operation::Engine::Halt => e
    e
  end

  def events
    ctx.scratch.trace.pluck('event')
  end

  before { ctx.open_scope!(:survey, session, 10.minutes.from_now) }

  it 'clicks to the form, accepts the R2 claim and returns the ops ending with wait_for' do
    session.on(:click) { session.show(form_page) }
    ai_answers(continue(action('click', ref: 'f0:e1')), form_reached('f0:e1', field_refs: %w[f0:e1 f0:e2 f0:e3], submit_ref: 'f0:e4'))

    expect(navigate).to eq([
      Apply::Recipe::Op::Click.new(target: job_page.elements[1]['target']).to_h,
      { 'op' => 'wait_for', 'root' => form_css, 'frame_path' => [], 'min_fields' => 3 }
    ])
    expect(ctx.form_root).to eq(ApplyMate::Client::Browser::Target.css(form_css))
    expect(ctx.form_url).to eq(job)
    expect(session.calls_of(:snapshot_all)).to include([ { markers: Apply::Platform::Registry.dom_markers, regions: [ form_css ] } ])
    expect(ctx.scratch.trace.find { |entry| entry['event'] == 'form_claim' }).to include('accepted' => true, 'reason' => 'identity_field')
    expect(apply.reload.ai_calls).to eq(2)
  end

  context 'when probe/anchor.js finds a stable selector for the claimed root (an id, a data-* attribute, the only form)' do
    let(:session) do
      FakeSession.new(html: '', final_url: job, snapshot: job_page, anchors: { form_css => { 'selector' => '#application-form' } })
    end
    let(:form_page) do
      page = super()
      # The fresh snapshot of the claim check is taken with regions: [root], so snapshot.js reports the new selector.
      page.with(elements: page.elements.map do |el|
        el.merge('regions' => Array(el['regions']).map { |region| region == form_css ? '#application-form' : region })
      end)
    end

    it 'stores the form root by that selector, not by its nth-of-type chain (an inserted banner must not shift it)' do
      session.on(:click) { session.show(form_page) }
      ai_answers(continue(action('click', ref: 'f0:e1')), form_reached('f0:e1', field_refs: %w[f0:e1 f0:e2 f0:e3], submit_ref: 'f0:e4'))

      expect(navigate.last).to include('op' => 'wait_for', 'root' => '#application-form')
      expect(ctx.form_root).to eq(ApplyMate::Client::Browser::Target.css('#application-form'))
      expect(session.calls_of(:probe)).to include([ :anchor, ApplyMate::Client::Browser::Target.css(form_css) ])
    end
  end

  it "passes the landing page's own title (its first h1) to every prompt" do
    session.show(job_page.with(frames: job_page.frames.map { |frame| frame.merge('outline' => [ 'h2 About', 'h1 Trainee FE Developer' ]) }))
    allow(Apply::Ai::Prompt::Navigate).to receive(:new).and_call_original
    ai_answers(continue(action('click', ref: 'f0:e1')), form_reached('f0:e1', field_refs: %w[f0:e1 f0:e2 f0:e3], submit_ref: 'f0:e4'))
    session.on(:click) { session.show(form_page) }

    navigate
    expect(Apply::Ai::Prompt::Navigate).to have_received(:new).with(hash_including(posting_title: 'Trainee FE Developer')).twice
  end

  it 'keeps the positional path when nothing on the way up is stable (anchor.js answers no selector)' do
    session.on(:click) { session.show(form_page) }
    ai_answers(continue(action('click', ref: 'f0:e1')), form_reached('f0:e1', field_refs: %w[f0:e1 f0:e2 f0:e3], submit_ref: 'f0:e4'))

    expect(navigate.last).to include('op' => 'wait_for', 'root' => form_css)
  end

  context 'when the claim leaves controls inside the form out of its field_refs (a helper upload, Preply)' do
    # f0:e0 tab, f0:e1..e3 name / email / phone, f0:e4 optional "Promo code", f0:e5 required "Portfolio", f0:e6 send
    let(:form_page) do
      inputs = [ [ 'Full name', 'text' ], [ 'Email', 'email' ], [ 'Phone', 'tel' ], [ 'Promo code', 'text' ], [ 'Portfolio', 'url' ] ]
      build_snapshot(frames: [ { url: job } ], elements: [
        snapshot_element(role: 'tab', name: 'Apply', selected: true, css: 'body > main > div > button:nth-of-type(2)'),
        *inputs.each_with_index.map do |(name, type), index|
          snapshot_element(name:, type:, required: name == 'Portfolio', css: "#{form_css} > input:nth-of-type(#{index + 1})",
                           regions: [ form_css ])
        end,
        snapshot_element(role: 'button', name: 'Submit application', submit_like: true, css: "#{form_css} > button",
                         regions: [ form_css ])
      ])
    end

    before { session.on(:click) { session.show(form_page) } }

    it 'remembers the optional controls it left out for DiscoverFields, never a required one' do
      ai_answers(continue(action('click', ref: 'f0:e1')), form_reached('f0:e1', field_refs: %w[f0:e1 f0:e2 f0:e3], submit_ref: 'f0:e6'))

      navigate
      expect(ctx.scratch.claim_left_out).to eq(Set["#{form_css} > input:nth-of-type(4)"])
      ctx.close_scope!
      expect(ctx.scratch.claim_left_out).to be_nil
    end

    it 'leaves nothing out when the claim left out more controls than it listed (a sloppy claim)' do
      ai_answers(continue(action('click', ref: 'f0:e1')), form_reached('f0:e1', field_refs: %w[f0:e1], submit_ref: 'f0:e6'))

      navigate
      expect(ctx.scratch.claim_left_out).to be_empty
    end
  end

  context 'when readiness.js sees fewer controls than the verdict counted (an upload chooser, a custom radio group)' do
    let(:session) { FakeSession.new(html: '', final_url: job, snapshot: job_page, rendered_fields: 1) }

    it 'stores the wait_for min_fields readiness.js measured, so the replay does not drift' do
      session.on(:click) { session.show(form_page) }
      ai_answers(continue(action('click', ref: 'f0:e1')), form_reached('f0:e1', field_refs: %w[f0:e1 f0:e2 f0:e3], submit_ref: 'f0:e4'))

      expect(navigate.last).to include('op' => 'wait_for', 'min_fields' => 1)
      expect(session.calls_of(:probe)).to include([ :readiness, ApplyMate::Client::Browser::Target.css(form_css), { 'min' => 1 } ])
    end
  end

  it 'never sends a value and wraps the page in the untrusted markers' do
    ai_answers(give_up('no_application_path'))
    halt_of

    expect(prompts.sole).to include('[f0:e1] tab "Apply"', ApplyMate::Ai::Prompt::Base::OPEN_MARK, '<empty>')
  end

  describe 'termination' do
    it 'halts stuck on the third identical state, after listing the repeated click under FORBIDDEN' do
      ai_answers(continue(action('click', ref: 'f0:e1')))

      expect(halt_of).to have_attributes(code: :stuck)
      expect(prompts.size).to eq(2)
      expect(prompts.first).to include('FORBIDDEN (repeated without effect): none')
      expect(prompts.last).to include('FORBIDDEN (repeated without effect): click(f0:e1)')
      expect(session.calls_of(:click).size).to eq(1) # the repeat was skipped, never performed again
    end

    it 'rejects a hallucinated ref without touching the page and tells the AI next turn' do
      ai_answers(continue(action('click', ref: 'f9:e99')), give_up('no_application_path'))

      expect(halt_of).to have_attributes(code: :no_application_path)
      expect(session.calls_of(:click)).to be_empty
      expect(ctx.scratch.trace.find { |entry| entry['event'] == 'action_rejected' }).to include('ref' => 'f9:e99', 'reason' => 'unknown_ref')
      expect(prompts.last).to include('click(f9:e99) was rejected: unknown_ref')
    end

    it 'halts budget_exhausted on turn 13 after exactly 12 AI requests while the page keeps changing' do
      step = 0
      session.on(:click) do
        step += 1
        session.show(build_snapshot(frames: [ { url: job } ], elements: [ snapshot_element(role: 'button', name: "Step #{step}") ]))
      end
      session.show(build_snapshot(frames: [ { url: job } ], elements: [ snapshot_element(role: 'button', name: 'Start') ]))
      ai_answers(continue(action('click', ref: 'f0:e0')))

      expect(halt_of).to have_attributes(code: :budget_exhausted)
      expect(a_request(:post, gemini)).to have_been_made.times(described_class::MAX_TURNS)
      expect(described_class::MAX_TURNS).to eq(12)
    end

    it 'halts invalid_ai_output after two invalid answers in a row' do
      ai_answers('not json at all', '{"status": "dance"}')

      expect(halt_of).to have_attributes(code: :invalid_ai_output)
      expect(prompts.size).to eq(2)
      expect(prompts.last).to include('Your previous answer was invalid')
      expect(apply.reload.ai_calls).to eq(2)
    end

    it 'asks again once after an invalid answer and goes on with the valid one' do
      session.on(:click) { session.show(form_page) }
      ai_answers('```json\n{"status": "continue"}\n```', continue(action('click', ref: 'f0:e1')),
                 form_reached('f0:e1', field_refs: %w[f0:e1 f0:e2 f0:e3]))

      expect(navigate.last).to include('op' => 'wait_for')
      expect(prompts.size).to eq(3)
    end

    it 'treats a give_up without a code as invalid output' do
      ai_answers(give_up(nil))

      expect(halt_of).to have_attributes(code: :invalid_ai_output)
    end

    it 'halts when the time budget is spent' do
      ctx.scratch.scope_deadline = 1.second.ago
      ai_answers(continue(action('click', ref: 'f0:e1')))

      expect(halt_of).to have_attributes(code: :deadline)
      expect(a_request(:post, gemini)).not_to have_been_made
    end
  end

  describe 'give_up' do
    it 'maps captcha_challenge to manual_apply_required (captcha)' do
      ai_answers(give_up('captcha_challenge'))

      expect(halt_of).to have_attributes(code: :manual_apply_required, detail: :captcha)
    end

    it 'halts with the code itself otherwise' do
      ai_answers(give_up('login_required'))

      expect(halt_of).to have_attributes(code: :login_required)
    end
  end

  describe 'form_reached' do
    it 'rejects an email-only form (R2), keeps looking and accepts the real one' do
      session.on(:click) { session.show(form_page) }
      ai_answers(form_reached('f0:e2'), continue(action('click', ref: 'f0:e1')),
                 form_reached('f0:e2', field_refs: %w[f0:e1 f0:e2 f0:e3], submit_ref: 'f0:e4'))

      ops = navigate

      claims = ctx.scratch.trace.select { |entry| entry['event'] == 'form_claim' }
      expect(claims.map { |claim| claim.slice('accepted', 'reason') }).to eq([
        { 'accepted' => false, 'reason' => 'too_few_fields' }, { 'accepted' => true, 'reason' => 'identity_field' }
      ])
      expect(prompts.second).to include('form_reached was rejected (too_few_fields)')
      expect(ops.map { |op| op['op'] }).to eq(%w[click wait_for])
      expect(ctx.form_root).to eq(ApplyMate::Client::Browser::Target.css(form_css))
    end

    it 'rejects a claim whose scope_ref is not on the page' do
      ai_answers(form_reached('f3:e7'), give_up('not_a_form'))

      expect(halt_of).to have_attributes(code: :not_a_form)
      expect(ctx.scratch.trace.find { |entry| entry['event'] == 'form_claim' }).to include('accepted' => false, 'reason' => 'no_root')
      expect(ctx.form_root).to be_nil
    end
  end

  it 'hands over to an adapter the page identified, without asking the AI' do
    ashby = Apply::Operation::Engine::Detect::Match.new(key: 'ashby', confidence: 0.95, captures: { 'slug' => 'acme' },
                                                         frame_path: nil, from_alias: false, probable: nil)
    allow(Apply::Operation::Engine::Observe).to receive(:call).and_wrap_original do |original, **options|
      original.call(**options).tap { ctx.adopt_match!(ashby) } # the rendered page showed an Ashby embed
    end
    ai_answers(give_up('no_application_path'))

    expect(navigate).to eq([])
    expect(events).to include('navigator_handover')
    expect(a_request(:post, gemini)).not_to have_been_made
  end

  # Owner decision 2026-10-09: no integration is refused. GeminiScraping (browser-backed, no native JSON schema) runs in
  # text mode inside the lease; its client is stubbed (no real Chrome).
  context 'with a GeminiScraping integration (text mode, slow)' do
    let(:client) { instance_double(ApplyMate::Ai::Client::GeminiScraping) }
    let(:requests) { [] }

    before do
      apply.ai_integration.update_columns(provider: 'gemini_scraping')
      allow(ApplyMate::Ai::Client::GeminiScraping).to receive(:new).and_return(client)
    end

    # Prose around a fenced JSON block, the way the web UI answers.
    def scraped(*answers)
      texts = answers.map { |answer| "Sure, here is my decision.\n```json\n#{answer.to_json}\n```\nGood luck!" }
      allow(client).to receive(:complete) do |request|
        requests << request
        ApplyMate::Ai::Response.new(text: texts.size > 1 ? texts.shift : texts.first, usage: ApplyMate::Ai::Usage::UNKNOWN)
      end
    end

    it 'navigates to the form from fenced prose answers, the client latency as the call timeout' do
      session.on(:click) { session.show(form_page) }
      scraped(continue(action('click', ref: 'f0:e1')), form_reached('f0:e1', field_refs: %w[f0:e1 f0:e2 f0:e3], submit_ref: 'f0:e4'))

      expect(navigate.last).to include('op' => 'wait_for', 'root' => form_css)
      expect(ctx.form_root).to eq(ApplyMate::Client::Browser::Target.css(form_css))
      expect(requests.size).to eq(2)
      expect(requests).to all(have_attributes(retries: 0, timeout: ApplyMate::Ai::Client::GeminiScraping::CALL_SECONDS))
      expect(requests.first.messages.sole[:content]).to include(Apply::Ai::ResponseSchema::Navigate.format_instructions)
      expect(a_request(:post, gemini)).not_to have_been_made
    end

    it 'gets a time budget sized for SCOPE_AI_CALLS slow calls (a 240 s turn outlives the fast 180 s budget)' do
      clock = 0.0
      allow_any_instance_of(described_class).to receive(:now) { clock } # rubocop:disable RSpec/AnyInstance
      texts = [ continue(action('click', ref: 'f0:e1')), give_up('no_application_path') ]
      allow(client).to receive(:complete) do
        clock += ApplyMate::Ai::Client::GeminiScraping::CALL_SECONDS # a slow answer
        ApplyMate::Ai::Response.new(text: "```json\n#{texts.shift.to_json}\n```", usage: ApplyMate::Ai::Usage::UNKNOWN)
      end

      expect(halt_of).to have_attributes(code: :no_application_path) # not :deadline after the first turn
      expect(client).to have_received(:complete).twice
    end

    it 'halts :deadline with a fast integration whose answer takes as long' do
      apply.ai_integration.update_columns(provider: 'gemini')
      clock = 0.0
      allow_any_instance_of(described_class).to receive(:now) { clock } # rubocop:disable RSpec/AnyInstance
      ai_answers(continue(action('click', ref: 'f0:e1')))
      allow(Apply::Operation::Engine::CallAi).to receive(:call).and_wrap_original do |original, **options|
        clock += ApplyMate::Ai::Client::GeminiScraping::CALL_SECONDS
        original.call(**options)
      end

      expect(halt_of).to have_attributes(code: :deadline)
    end
  end
end
