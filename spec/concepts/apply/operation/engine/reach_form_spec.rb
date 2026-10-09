# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::ReachForm do
  let(:apply) { create(:apply, entry_url: 'https://acme.example/jobs/1') }
  let(:ctx) { engine_context(apply) }
  let(:unwrap) { { 'op' => 'unwrap', 'url_template' => '{canonical_form_url}' } }

  def reach!
    described_class.call(ctx:).model
  end

  context 'with a scripted session' do
    let(:canonical) { 'https://jobs.example.com/acme/1/application' }
    let(:recipe) { nil }
    let(:missing) { [] }
    let(:current) { 'about:blank' }
    let(:session) { FakeSession.new(html: '', final_url: current, missing:, snapshot: form_page) }
    # The page a stored WaitFor('#form') checks with R2: name, email, phone inside the root.
    let(:form_page) do
      build_snapshot(frames: [ { url: 'https://acme.example/jobs/1' } ], elements: [ 'Full name', 'Email', 'Phone' ].map { |name|
        snapshot_element(name:, regions: [ '#form' ])
      })
    end
    let(:platform_class) do
      canonical_url = canonical
      recipe_ops = recipe
      Class.new(Apply::Platform::Base) do
        define_singleton_method(:key) { 'spec_form' }
        define_method(:canonical_form_url) { canonical_url }
        define_method(:navigation_recipe) { recipe_ops }
        define_method(:form_root_selector) { '#form' }
      end
    end

    before do
      match = Apply::Operation::Engine::Detect::Match.new(key: 'spec_form', confidence: 0.9, captures: {}, frame_path: nil,
                                                          from_alias: false, probable: nil)
      ctx.scratch.match = match
      ctx.scratch.platform = platform_class.new(ctx:, match:)
      ctx.open_scope!(:survey, session, 5.minutes.from_now)
    end

    it 'unwraps the canonical form URL, runs the after_goto gates and redetects, then waits for readiness' do
      expect(reach!).to eq([ unwrap ])
      expect(session.calls_of(:goto)).to eq([ [ canonical ] ])
      expect(session.calls_of(:snapshot_all)).to include([ { markers: Apply::Platform::Registry.dom_markers } ])
      expect(session.calls_of(:ready?).first).to eq([ ApplyMate::Client::Browser::Target.css('#form'), { timeout: 0, min_fields: 3 } ])
      expect(ctx.form_root).to eq(ApplyMate::Client::Browser::Target.css('#form'))
      expect(ctx.scratch.canonical_unwrapped).to eq([ 'spec_form' ])
      expect(ctx.scratch.trace.pluck('event')).to eq(%w[recipe_op form_ready])
    end

    it 'clamps the readiness wait to the time left' do
      ctx.scratch.scope_deadline = 4.seconds.from_now
      reach!

      expect(session.calls_of(:wait_until).sole.sole[:timeout]).to be <= 4
    end

    context 'when the session is already on the canonical page (host + path)' do
      let(:current) { "#{canonical}/?utm_source=dou" }

      it 'does not navigate and checks the current page' do
        expect(reach!).to eq([])
        expect(session.calls_of(:goto)).to be_empty
        expect(ctx.form_url).to eq(current)
      end
    end

    context 'when the canonical URL was already opened in this session' do
      let(:current) { 'https://acme.example/careers' }

      it 'never navigates to it twice' do
        ctx.scratch.canonical_unwrapped << 'spec_form'

        expect(reach!).to eq([])
        expect(session.calls_of(:goto)).to be_empty
      end
    end

    context 'when the canonical page never gets ready but the navigation recipe does' do
      let(:recipe) { [ { 'op' => 'goto', 'url_template' => '{entry_url}' } ] }
      let(:missing) { [ '#form' ] }

      it 'runs the recipe and returns it as the navigation' do
        session.on(:goto) { |url| missing.clear if url == ctx.entry_url }

        expect(reach!).to eq(recipe)
        expect(session.calls_of(:goto)).to eq([ [ canonical ], [ ctx.entry_url ] ])
      end
    end

    context 'when no path gets ready' do
      let(:recipe) { [ { 'op' => 'goto', 'url_template' => '{entry_url}' } ] }
      let(:missing) { [ '#form' ] }

      it 'halts not_a_form after one readiness wait per path (the current page is not polled again)' do
        expect { reach! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
          expect(halt).to have_attributes(code: :not_a_form, detail: 'form not reached')
        }
        expect(session.calls_of(:wait_until).size).to eq(2)
        expect(ctx.form_root).to be_nil
      end
    end

    context 'when nothing can navigate and the lease is still on about:blank' do
      let(:canonical) { nil }

      it 'halts not_a_form without waiting' do
        expect { reach! }.to raise_error(Apply::Operation::Engine::Halt, /not_a_form/)
        expect(session.calls_of(:wait_until)).to be_empty
      end
    end

    context 'when the adapter recipe clicks a target that is gone (drift)' do
      let(:canonical) { nil }
      let(:current) { 'https://acme.example/jobs/1' }
      let(:recipe) { [ { 'op' => 'click', 'target' => ApplyMate::Client::Browser::Target.css('a.apply').to_h } ] }
      let(:missing) { [ 'a.apply' ] }

      it 'traces the drift, counts the path as not ready and lets the Navigator heal from the drifted op' do
        navigator = []
        allow(Apply::Operation::Engine::Navigate).to receive(:call) do |ctx:, heal_hint:|
          navigator << heal_hint
          raise Apply::Operation::Engine::Halt.new(:no_application_path, detail: 'gave up')
        end

        expect { reach! }.to raise_error(Apply::Operation::Engine::Halt, /no_application_path/)
        expect(ctx.scratch.trace.find { |entry| entry['event'] == 'recipe_drift' }).to include('op' => recipe.first)
        expect(navigator.sole.to_h).to eq(recipe.first)
        expect(session.calls_of(:wait_until)).to be_empty
      end
    end

    describe 'replaying a stored navigation (navigation:)' do
      let(:current) { 'https://acme.example/jobs/1' }
      let(:tab) { 'https://acme.example/jobs/1/apply' }
      let(:click) { { 'op' => 'click', 'target' => ApplyMate::Client::Browser::Target.css('a.apply').to_h } }
      let(:wait_for) { { 'op' => 'wait_for', 'root' => '#form', 'frame_path' => [], 'min_fields' => 3 } }
      let(:stored) { [ { 'op' => 'goto', 'url_template' => '{entry_url}' }, click, wait_for ] }

      def replay!
        described_class.call(ctx:, navigation: stored).model
      end

      it 'replays it through Interpret and stops at its WaitFor (no canonical unwrap, no second readiness wait)' do
        expect(replay!).to eq(stored)
        expect(session.calls_of(:goto)).to eq([ [ ctx.entry_url ] ])
        expect(session.calls_of(:click).map(&:first)).to eq([ ApplyMate::Client::Browser::Target.css('a.apply') ])
        expect(session.calls_of(:ready?)).to eq([ [ ApplyMate::Client::Browser::Target.css('#form'), { timeout: 30, min_fields: 3 } ] ])
        expect(ctx.form_root).to eq(ApplyMate::Client::Browser::Target.css('#form'))
      end

      it 'returns the switch_tab a click inserted' do
        session.on(:click) { session.open_page(tab) }

        expect(replay!).to eq([ stored[0], click, { 'op' => 'switch_tab', 'index' => 1 }, wait_for ])
        expect(ctx.form_url).to eq(tab)
      end

      context 'without a WaitFor (a 3a navigation)' do
        let(:stored) { [ unwrap ] }

        it 'waits for the platform readiness after it' do
          expect(replay!).to eq([ unwrap ])
          expect(session.calls_of(:ready?).first).to eq([ ApplyMate::Client::Browser::Target.css('#form'), { timeout: 0, min_fields: 3 } ])
          expect(ctx.scratch.canonical_unwrapped).to eq([ 'spec_form' ])
        end
      end

      context 'when the stored click target is gone' do
        let(:missing) { [ 'a.apply' ] }

        it 'traces recipe_drift and falls back to the canonical unwrap' do
          expect(replay!).to eq([ unwrap ])
          expect(session.calls_of(:goto)).to eq([ [ ctx.entry_url ], [ canonical ] ])
          expect(ctx.scratch.trace.pluck('event')).to include('recipe_drift')
          expect(ctx.form_root).to eq(ApplyMate::Client::Browser::Target.css('#form'))
        end
      end
    end

    it 'stops on a gate after the navigation (Google Forms)' do
      snapshot = FakeSession::EMPTY_SNAPSHOT.with(evidence: FakeSession::EMPTY_SNAPSHOT.evidence.merge(
        frame_urls: [ 'https://docs.google.com/forms/d/e/1/viewform' ]
      ))
      allow(session).to receive(:snapshot_all).and_return(snapshot)

      expect { reach! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :manual_apply_required, detail: :google_forms)
      }
    end
  end

  context 'with a platform not identified yet (generic, Ashby probable at the HTTP level)' do
    let(:careers) { 'https://acme.example/careers?ashby_jid=1' }
    let(:frame_urls) { [ careers ] }
    let(:session) do
      evidence = { frame_urls:, script_srcs: [], iframe_srcs: [], dom_markers: {} }
      FakeSession.new(html: '', final_url: careers, snapshot: FakeSession::EMPTY_SNAPSHOT.with(evidence:))
    end

    before do
      allow(session).to receive(:current_url) { session.calls_of(:goto).last&.first || 'about:blank' }
      ctx.evidence = Apply::Operation::Engine::Detect::Evidence.build(current_urls: [ careers ], hops: [ apply.entry_url, careers ])
      apply.landing_url = careers
      ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.generic)
      ctx.open_scope!(:survey, session, 5.minutes.from_now)
    end

    # The Navigator's part (its own spec covers the loop): a click, then the R2-accepted root.
    let(:navigator_ops) do
      [ { 'op' => 'click', 'target' => ApplyMate::Client::Browser::Target.css('a.apply').to_h },
        { 'op' => 'wait_for', 'root' => 'form', 'frame_path' => [], 'min_fields' => 3 } ]
    end

    def stub_navigator
      allow(Apply::Operation::Engine::Navigate).to receive(:call) do |ctx:, heal_hint:|
        ctx.form_root = ApplyMate::Client::Browser::Target.css('form')
        ctx.form_url = careers
        instance_double(ApplyMate::Operation::Result, model: navigator_ops)
      end
    end

    it 'opens the final URL of the redirect walk, waits IDENTIFY_TIMEOUT there (nothing probable), then hands over to the Navigator' do
      stub_navigator

      expect(reach!).to eq([ { 'op' => 'goto', 'url_template' => '{landing_url}' }, *navigator_ops ])
      expect(session.calls_of(:goto)).to eq([ [ careers ] ])
      expect(session.calls_of(:wait_until).sole.sole[:timeout]).to eq(described_class::IDENTIFY_TIMEOUT)
      # Generic is ai_only: no readiness poll claims the page; the landing only asks whether a form is rendered yet.
      body = ApplyMate::Client::Browser::Target.css('body')
      expect(session.calls_of(:ready?)).to eq([ [ body, { timeout: 0, min_fields: Apply::Operation::Engine::WaitReady::DEFAULT_MIN_FIELDS } ] ])
      expect(ctx.scratch.trace.find { |entry| entry['event'] == 'landed' }).to include('identified' => false)
      expect(Apply::Operation::Engine::Navigate).to have_received(:call).with(ctx:, heal_hint: nil)
    end

    it 'ends the identify wait at the first poll when the landing already renders a form (an SSR page)' do
      stub_navigator

      reach!

      expect(ctx.scratch.trace.find { |entry| entry['event'] == 'landed' }).to include('identified' => false, 'form_rendered' => true)
    end

    context 'when the landing renders no form yet' do
      let(:session) do
        evidence = { frame_urls:, script_srcs: [], iframe_srcs: [], dom_markers: {} }
        FakeSession.new(html: '', final_url: careers, snapshot: FakeSession::EMPTY_SNAPSHOT.with(evidence:), missing: [ 'body' ])
      end

      it 'keeps polling for the platform (the wait does not end on the form check)' do
        stub_navigator

        reach!

        expect(ctx.scratch.trace.find { |entry| entry['event'] == 'landed' }).to include('identified' => false, 'form_rendered' => false)
      end
    end

    it 'waits LANDING_TIMEOUT (clamped to the time left) when the HTTP level found a probable platform' do
      stub_navigator
      probable = Apply::Operation::Engine::Detect::Match.new(key: 'ashby', confidence: 0.5, captures: {}, frame_path: nil,
                                                             from_alias: false, probable: nil)
      ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.generic(probable:))
      ctx.scratch.scope_deadline = 7.seconds.from_now

      reach!

      expect(session.calls_of(:wait_until).sole.sole[:timeout]).to be_between(6, 7)
    end

    it 'does not land again on a session that already shows a page' do
      stub_navigator
      session.goto(careers)

      expect(reach!).to eq(navigator_ops)
      expect(session.calls_of(:goto)).to eq([ [ careers ] ])
      expect(session.calls_of(:wait_until)).to be_empty
    end

    it 'halts not_a_form without the Navigator when the lease stays blank (nothing to look at)' do
      allow(session).to receive(:current_url).and_return('about:blank')
      allow(Apply::Operation::Engine::Navigate).to receive(:call)

      expect { reach! }.to raise_error(Apply::Operation::Engine::Halt, /not_a_form/)
      expect(Apply::Operation::Engine::Navigate).not_to have_received(:call)
    end

    context 'when the Navigator hands over to a platform it identified (no form root yet)' do
      it "runs that adapter's paths once more" do
        allow(Apply::Operation::Engine::Navigate).to receive(:call) do |ctx:, heal_hint:|
          ctx.scratch.match = Apply::Operation::Engine::Detect::Match.new(key: 'spec_form', confidence: 0.9, captures: {},
                                                                          frame_path: nil, from_alias: false, probable: nil)
          ctx.scratch.platform = Class.new(Apply::Platform::Base) {
            define_singleton_method(:key) { 'spec_form' }
            define_method(:form_root_selector) { '#form' }
          }.new(ctx:, match: ctx.match)
          instance_double(ApplyMate::Operation::Result, model: navigator_ops.first(1))
        end

        expect(reach!).to eq([ { 'op' => 'goto', 'url_template' => '{landing_url}' }, navigator_ops.first ])
        expect(ctx.form_root).to eq(ApplyMate::Client::Browser::Target.css('#form'))
      end
    end

    context 'when the rendered page carries the Ashby embed' do
      let(:jid) { '20587adf-cf02-473e-8a80-7b009711a2cf' }
      let(:frame_urls) { [ careers, "https://jobs.ashbyhq.com/acme/#{jid}?embed=js" ] }

      it 'adopts Ashby, reads its schema once and unwraps the canonical form' do
        schema = [ answer_field(id: 'ashby:_systemfield_email') ]
        allow_any_instance_of(Apply::Platform::Ashby).to receive(:fetch_schema).and_return(schema)

        expect(reach!).to eq([ { 'op' => 'goto', 'url_template' => '{landing_url}' }, unwrap ])
        expect(ctx.match).to have_attributes(key: 'ashby', captures: { 'slug' => 'acme', 'jid' => jid })
        expect(ctx.schema).to eq(schema)
        expect(session.calls_of(:goto).last).to eq([ "https://jobs.ashbyhq.com/acme/#{jid}/application" ])
        expect(session.calls_of(:ready?).last.last).to include(keys: [ '_systemfield_email' ], attr: 'data-field-path')
      end
    end
  end

  context 'on the fixture site', :browser do
    before { adopt_fixture_ashby!(ctx) }

    it 'unwraps the canonical URL from a fresh lease and finds the form by the schema keys' do
      in_fixture_scope(ctx) do |session|
        allow(session).to receive(:ready?).and_call_original

        expect(reach!).to eq([ unwrap ])
        expect(session.current_url).to eq(ctx.platform.canonical_form_url)
        expect(ctx.form_url).to eq(ctx.platform.canonical_form_url)
        expect(ctx.form_root).to eq(ApplyMate::Client::Browser::Target.css('#form[role="tabpanel"]'))
        expect(session).to have_received(:ready?)
          .with(anything, timeout: 0, keys: ctx.schema_keys, attr: 'data-field-path', ratio: 0.8,
                          key_prefix: Apply::Platform::Ashby::INSTANCE_PREFIX_SOURCE).at_least(:once)
      end
    end

    it 'finds the form root inside the cross-origin embed iframe (its iframe#id frame path)' do
      in_fixture_scope(ctx) do |session|
        ctx.scratch.canonical_unwrapped << 'ashby'
        session.goto(FixtureSite.url('/ashby/embedded_application.html'))

        expect(reach!).to eq([])
        expect(ctx.form_root).to eq(ApplyMate::Client::Browser::Target.css(
          '#form[role="tabpanel"]', frame_path: [ { 'selector' => 'iframe#ashby_embed_iframe' } ]
        ))
        expect(session.present?(ctx.form_root, visibility: :required)).to be(true)
      end
    end

    it 'halts not_a_form when the schema keys never appear (the Navigator gives up too)' do
      stub_const("#{described_class}::READY_TIMEOUT", 2)
      stub_request(:post, %r{generativelanguage\.googleapis\.com.*generateContent}).to_return(gemini_json_response(
        { status: 'give_up', reason: 'no form', actions: [], form: nil, give_up_code: 'not_a_form' }.to_json
      ))
      in_fixture_scope(ctx) do |session|
        ctx.scratch.canonical_unwrapped << 'ashby'
        session.goto(FixtureSite.url('/form.html'))

        expect { reach! }.to raise_error(Apply::Operation::Engine::Halt, /not_a_form/)
      end
    end
  end
end
