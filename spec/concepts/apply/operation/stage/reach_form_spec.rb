# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Stage::ReachForm do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:jid) { '20587adf-cf02-473e-8a80-7b009711a2cf' }
  let(:canonical) { "https://jobs.ashbyhq.com/preply/#{jid}/application" }
  let(:session) { FakeSession.new(html: '', final_url: canonical) }
  let(:form_root) { ApplyMate::Client::Browser::Target.css('#form[role="tabpanel"]') }
  let(:unwrap) { { 'op' => 'unwrap', 'url_template' => '{canonical_form_url}' } }

  def adopt_ashby(context)
    context.adopt_match!(Apply::Operation::Engine::Detect::Match.new(
      key: 'ashby', confidence: 0.95, captures: { 'slug' => 'preply', 'jid' => jid }, frame_path: nil, from_alias: false,
      probable: nil
    ))
  end

  before do
    adopt_ashby(ctx)
    ctx.open_scope!(:survey, session, 5.minutes.from_now)
    allow(session).to receive(:current_url).and_return('about:blank', canonical)
  end

  it 'has a localized stage name' do
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :uk)).to be_present
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :en)).to be_present
  end

  it 'reaches the form and persists the navigation and the form URL' do
    result = described_class.call(ctx:)

    expect(session.calls_of(:goto)).to eq([ [ canonical ] ])
    expect(result[:step_result]).to eq('navigation' => [ unwrap ], 'form_url' => canonical,
                                       'form_root' => form_root.to_h.deep_stringify_keys, 'platform' => 'ashby', 'schema' => 0)
    expect(apply.reload).to have_attributes(navigation: [ unwrap ], form_url: canonical, platform: 'ashby',
                                            apply_key: "ashby:preply:#{jid}")
    expect(ctx).to have_attributes(form_url: canonical, form_root:)
  end

  it 'halts not_a_form when the form never gets ready and the Navigator gives up as well' do
    allow(session).to receive(:ready?).and_return(false)
    stub_request(:post, %r{generativelanguage\.googleapis\.com.*generateContent}).to_return(gemini_json_response(
      { status: 'give_up', reason: 'no form here', actions: [], form: nil, give_up_code: 'not_a_form' }.to_json
    ))

    expect { described_class.call(ctx:) }.to raise_error(Apply::Operation::Engine::Halt, /not_a_form/)
    expect(apply.reload.navigation).to be_nil
  end

  it 'restores the form URL and the form root a later scope needs' do
    result = described_class.call(ctx:)[:step_result]
    fresh = Apply::Operation::Engine::Context.new(**ctx.to_h, scratch: Apply::Operation::Engine::Context::Scratch.new)

    described_class.restore(fresh, JSON.parse(result.to_json))

    expect(fresh).to have_attributes(form_url: canonical, form_root:)
  end

  context 'when the job id has a digit run Redact reads as a phone number' do
    let(:jid) { '4a1b2c3d-1234-5678-9012-345678901abc' }

    it 'restores the form URL from applies.form_url, not from the redacted step result' do
      result = described_class.call(ctx:)[:step_result]
      redacted = Apply::Operation::Engine::RedactTree.call(value: JSON.parse(result.to_json), apply:).model
      fresh = Apply::Operation::Engine::Context.new(**ctx.to_h, apply: apply.reload, scratch: Apply::Operation::Engine::Context::Scratch.new)

      described_class.restore(fresh, redacted)

      expect(redacted['form_url']).to include('{{phone}}')
      expect(fresh.form_url).to eq(canonical)
    end
  end

  context 'when the landing page identifies a platform the HTTP level only found probable (generic -> ashby)' do
    let(:preply) { "https://preply.com/en/careers/apply?ashby_jid=#{jid}" }
    let(:embed) { "https://jobs.ashbyhq.com/preply/#{jid}?embed=js" }
    let(:frame_urls) { [ preply, embed ] }
    let(:snapshot) do
      FakeSession::EMPTY_SNAPSHOT.with(evidence: { frame_urls:, script_srcs: [], iframe_srcs: frame_urls.drop(1), dom_markers: {} })
    end
    let(:session) { FakeSession.new(html: '', final_url: canonical, snapshot:) }
    let(:posting) { ApplyMate::Client::Response.new(file_fixture('apply_engine/ashby/api_job_posting.json').read, {}, 200, nil) }
    let(:landing) { { 'op' => 'goto', 'url_template' => '{landing_url}' } }

    def generic_ctx(context)
      context.evidence = Apply::Operation::Engine::Detect::Evidence.build(current_urls: [ preply ], hops: [ 'https://dou.ua/goto/vacancy/?id=1', preply ])
      context.redetect!(context.evidence)
    end

    before do
      allow(session).to receive(:current_url) { session.calls_of(:goto).last&.first || 'about:blank' }
      allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call) { |url:| FixtureSite.resolution(url) }
      allow(ctx.http).to receive(:post).and_return(posting)
      ctx.scratch.match = nil
      generic_ctx(ctx)
      apply.update_columns(platform: 'generic', platform_match: ctx.match.to_h, landing_url: preply)
    end

    it 'lands on the careers page, reads the schema, unwraps the canonical form and persists the new detection' do
      result = described_class.call(ctx:)[:step_result]

      expect(session.calls_of(:goto)).to eq([ [ preply ], [ canonical ] ])
      expect(result).to include('navigation' => [ landing, unwrap ], 'platform' => 'ashby', 'schema' => 15)
      expect(apply.reload).to have_attributes(platform: 'ashby', apply_key: "ashby:preply:#{jid}", form_url: canonical,
                                              navigation: [ landing, unwrap ])
      expect(apply.platform_match).to include('key' => 'ashby', 'captures' => { 'slug' => 'preply', 'jid' => jid })
    end

    it 'reaches the form with a GeminiScraping integration without asking the AI inside the lease' do
      apply.ai_integration.update!(provider: 'gemini_scraping')
      allow(ApplyMate::Ai::Client::GeminiScraping).to receive(:new)

      result = described_class.call(ctx:)[:step_result]

      expect(result).to include('navigation' => [ landing, unwrap ], 'platform' => 'ashby')
      expect(ApplyMate::Ai::Client::GeminiScraping).not_to have_received(:new)
      expect(apply.reload.ai_calls).to eq(0)
    end

    it 'restores the switched platform and the schema it read on a later attempt (the digest matches again)' do
      digest = described_class.input_digest(ctx)
      result = described_class.call(ctx:)[:step_result]
      apply.update!(fields: ctx.schema.map(&:to_h)) # what DiscoverFields persists (schema_api fields)
      fresh = Apply::Operation::Engine::Context.new(**ctx.to_h, apply: apply.reload, scratch: Apply::Operation::Engine::Context::Scratch.fresh)
      generic_ctx(fresh)

      expect(described_class.input_digest(fresh)).to eq(digest)
      described_class.restore(fresh, Apply::Operation::Engine::RedactTree.call(value: JSON.parse(result.to_json), apply:).model)

      expect(fresh.match).to have_attributes(key: 'ashby', captures: { 'slug' => 'preply', 'jid' => jid })
      expect(fresh.platform).to be_a(Apply::Platform::Ashby)
      expect(fresh.schema.map(&:id)).to match_array(ctx.schema.map(&:id))
      expect(fresh).to have_attributes(form_url: canonical, form_root:)
    end

    it 'halts already_applied when the now known posting was submitted by another apply' do
      create(:apply, :completed, user: apply.user, apply_key: "ashby:preply:#{jid}")

      expect { described_class.call(ctx:) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt.code).to eq(:already_applied)
      }
    end

    context 'when the landing page shows no known platform (Generic: the AI Navigator reaches the form)' do
      let(:form_css) { 'body > main > form' }
      # f0:e0 the Apply button; after the click f0:e1..e3 name / email / phone in the form
      let(:job_page) do
        build_snapshot(frames: [ { url: preply } ], elements: [ snapshot_element(role: 'button', name: 'Apply now') ])
      end
      let(:form_page) do
        build_snapshot(frames: [ { url: preply } ], elements: [
          snapshot_element(role: 'button', name: 'Apply now', expanded: true),
          *[ 'Full name', 'Email', 'Phone' ].each_with_index.map { |name, index|
            snapshot_element(name:, css: "#{form_css} > input:nth-of-type(#{index + 1})", regions: [ form_css ])
          }
        ])
      end
      let(:session) { FakeSession.new(html: '', final_url: preply, snapshot: job_page) }
      let(:answers) do
        [ { status: 'continue', reason: 'open the form', form: nil, give_up_code: nil,
            actions: [ { type: 'click', ref: 'f0:e0', key: nil, index: nil, max_ms: nil } ] },
          { status: 'form_reached', reason: 'name, email, phone', actions: [], give_up_code: nil,
            form: { frame: 'f0', scope_ref: 'f0:e1', field_refs: %w[f0:e1 f0:e2 f0:e3], submit_ref: nil, advance_ref: nil } } ]
      end

      before do
        session.on(:click) { session.show(form_page) }
        stub_request(:post, %r{generativelanguage\.googleapis\.com.*generateContent})
          .to_return(*answers.map { |answer| gemini_json_response(answer.to_json) })
      end

      it 'persists the navigation [goto {landing_url}, click, wait_for] and the form URL' do
        navigation = [ landing, Apply::Recipe::Op::Click.new(target: job_page.elements.first['target']).to_h,
                       { 'op' => 'wait_for', 'root' => form_css, 'frame_path' => [], 'min_fields' => 3 } ]

        result = described_class.call(ctx:)[:step_result]

        expect(result).to include('navigation' => navigation, 'form_url' => preply, 'platform' => 'generic',
                                  'form_root' => ApplyMate::Client::Browser::Target.css(form_css).to_h.deep_stringify_keys)
        expect(apply.reload).to have_attributes(platform: 'generic', navigation:, form_url: preply, ai_calls: 2)
        expect(session.calls_of(:goto)).to eq([ [ preply ] ])
        expect(session.calls_of(:ready?)).to be_empty
        expect(ctx.scratch.trace.pluck('event')).to include('landed', 'navigator_turn', 'navigate', 'form_claim')
      end

      it 'persists nothing when the Navigator gives up' do
        stub_request(:post, %r{generativelanguage\.googleapis\.com.*generateContent}).to_return(gemini_json_response(
          { status: 'give_up', reason: 'login', actions: [], form: nil, give_up_code: 'login_required' }.to_json
        ))

        expect { described_class.call(ctx:) }.to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:login_required) }
        expect(apply.reload).to have_attributes(navigation: nil, form_url: nil)
      end
    end
  end

  context 'with replay: true (the submit scope) and a stored navigation' do
    let(:job) { 'https://acme.example/jobs/1' }
    let(:click) { { 'op' => 'click', 'target' => ApplyMate::Client::Browser::Target.css('a.apply').to_h } }
    let(:wait_for) { { 'op' => 'wait_for', 'root' => '#form[role="tabpanel"]', 'frame_path' => [], 'min_fields' => 3 } }
    let(:stored) { [ { 'op' => 'goto', 'url_template' => '{entry_url}' }, click, wait_for ] }
    let(:missing) { [] }
    let(:session) { FakeSession.new(html: '', final_url: job, missing:, snapshot: form_page) }
    # What the stored WaitFor's root holds: an application form by R2.
    let(:form_page) do
      build_snapshot(frames: [ { url: job } ], elements: [ 'Full name', 'Email', 'Phone' ].map { |name|
        snapshot_element(name:, regions: [ form_root.strategies.first['css'] ])
      })
    end

    before do
      apply.update_columns(entry_url: job, navigation: stored, form_url: job)
      allow(session).to receive(:current_url).and_call_original
      ctx.scratch.scope = :submit
    end

    it 'replays it through Interpret and persists what it performed, with the switch_tab a new tab inserted' do
      session.on(:click) { session.open_page(canonical) }
      performed = [ stored[0], click, { 'op' => 'switch_tab', 'index' => 1 }, wait_for ]

      result = described_class.call(ctx:, replay: true)[:step_result]

      expect(session.calls_of(:goto)).to eq([ [ job ] ])
      expect(session.calls_of(:click).map(&:first)).to eq([ ApplyMate::Client::Browser::Target.css('a.apply') ])
      expect(session.calls_of(:ready?).map(&:first)).to eq([ form_root ])
      expect(result).to include('navigation' => performed, 'form_url' => canonical)
      expect(apply.reload).to have_attributes(navigation: performed, form_url: canonical)
    end

    context 'when the stored navigation drifted (the Apply link is gone)' do
      let(:missing) { [ 'a.apply' ] }

      it 'traces recipe_drift, reaches the form the survey way and persists that navigation' do
        allow(session).to receive(:current_url) { session.calls_of(:goto).last&.first || 'about:blank' }

        result = described_class.call(ctx:, replay: true)[:step_result]

        expect(session.calls_of(:goto)).to eq([ [ job ], [ canonical ] ])
        expect(result['navigation']).to eq([ unwrap ])
        expect(apply.reload.navigation).to eq([ unwrap ])
        expect(ctx.scratch.trace.pluck('event')).to include('recipe_drift')
      end
    end

    context 'when the stored navigation of a Generic form drifted' do
      let(:missing) { [ 'a.apply' ] }

      it 'heals with the Navigator, the drifted op as its hint, and persists the healed navigation' do
        ctx.scratch.match = nil
        ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.generic)
        healed = [ { 'op' => 'click', 'target' => ApplyMate::Client::Browser::Target.css('a.apply-now').to_h }, wait_for ]
        allow(Apply::Operation::Engine::Observe).to receive(:call).and_wrap_original do |original, **options|
          original.call(**options).tap { ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.generic) } # still nothing known
        end
        allow(Apply::Operation::Engine::Navigate).to receive(:call) do |ctx:, heal_hint:|
          ctx.form_root = form_root
          ctx.form_url = job
          instance_double(ApplyMate::Operation::Result, model: healed)
        end

        result = described_class.call(ctx:, replay: true)[:step_result]

        expect(Apply::Operation::Engine::Navigate).to have_received(:call)
          .with(ctx:, heal_hint: an_object_having_attributes(to_h: click))
        expect(result['navigation']).to eq([ stored.first, *healed ])
        expect(apply.reload.navigation).to eq([ stored.first, *healed ])
      end
    end

    it 'reaches the form the survey way when nothing is stored' do
      apply.update_columns(navigation: nil)
      allow(session).to receive(:current_url).and_return('about:blank', canonical)

      expect(described_class.call(ctx:, replay: true)[:step_result]['navigation']).to eq([ unwrap ])
    end

    it 'does not replay outside replay mode (the survey re-reaches the form)' do
      allow(session).to receive(:current_url).and_return('about:blank', canonical)

      described_class.call(ctx:)

      expect(session.calls_of(:goto)).to eq([ [ canonical ] ])
    end
  end

  describe '.input_digest' do
    it 'is stable for the same match and schema' do
      expect(described_class.input_digest(ctx)).to eq(described_class.input_digest(ctx))
    end

    it 'changes with the schema ids' do
      base = described_class.input_digest(ctx)
      ctx.schema = [ answer_field(id: 'ashby:_systemfield_email') ]

      expect(described_class.input_digest(ctx)).not_to eq(base)
    end

    it 'is nil on replay (always re-runs)' do
      expect(described_class.input_digest(ctx, replay: true)).to be_nil
    end
  end
end
