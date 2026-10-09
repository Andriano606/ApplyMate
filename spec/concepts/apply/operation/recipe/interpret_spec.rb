# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Recipe::Interpret do
  let(:apply) { create(:apply, entry_url: 'https://acme.example/jobs/1') }
  let(:ctx) { engine_context(apply) }
  let(:job) { 'https://acme.example/jobs/1' }
  let(:form) { 'https://apply.acme.example/form/1' }
  let(:missing) { [] }
  let(:session) { FakeSession.new(html: '', final_url: job, missing:, snapshot: form_page) }
  # What the WaitFor root holds: an application form by R2 (name, email, phone).
  let(:form_page) do
    build_snapshot(frames: [ { url: job } ], elements: [ 'Full name', 'Email', 'Phone' ].map { |name|
      snapshot_element(name:, regions: [ 'form#apply' ])
    })
  end
  let(:apply_link) { ApplyMate::Client::Browser::Target.css('a.apply', has_text: 'Apply') }
  let(:goto) { { 'op' => 'goto', 'url_template' => '{entry_url}' } }
  let(:click) { { 'op' => 'click', 'target' => apply_link.to_h } }
  let(:wait_for) { { 'op' => 'wait_for', 'root' => 'form#apply', 'frame_path' => [], 'min_fields' => 2 } }

  def interpret(ops)
    described_class.call(ctx:, ops:).model
  end

  def recipe_trace(key)
    ctx.scratch.trace.select { |entry| entry['event'] == 'recipe_op' }.pluck(key)
  end

  before do
    ctx.open_scope!(:survey, session, 5.minutes.from_now)
    allow(Apply::Operation::Engine::RunGates).to receive(:call).and_call_original
  end

  it 'performs the ops in order, observes after each and returns the performed op hashes' do
    expect(interpret([ goto, click, wait_for ])).to eq([ goto, click, wait_for ])

    expect(session.calls.map(&:first) - %i[current_url pages]).to eq(
      %i[goto snapshot_all probe snapshot_all click settle snapshot_all ready? snapshot_all snapshot_all]
    )
    # the last look is verify_form!'s: the form regions for R2
    expect(session.calls_of(:snapshot_all).last).to eq([ { markers: Apply::Platform::Registry.dom_markers, regions: [ 'form#apply' ] } ])
    expect(session.calls_of(:probe)).to eq([ [ :opens_tab, apply_link ] ])
    expect(ctx.form_root).to eq(ApplyMate::Client::Browser::Target.css('form#apply'))
    expect(ctx.form_url).to eq(job)
    expect(ctx.scratch.trace.select { |entry| entry['event'] == 'recipe_op' }.map { |entry| entry.values_at('op', 'platform', 'url') })
      .to eq([ [ 'goto', 'generic', job ], [ 'click', 'generic', job ], [ 'wait_for', 'generic', job ] ])
  end

  it 'runs the after_goto gates after a navigation and the after_action gates after an action' do
    interpret([ goto, click, wait_for ])

    events = []
    expect(Apply::Operation::Engine::RunGates).to have_received(:call).exactly(4).times do |event:, **|
      events << event
    end
    # the click: GuardAction's gates before it, Interpret's after it
    expect(events).to eq(%i[after_goto after_action after_action after_action])
  end

  it 'accepts op objects as well as hashes' do
    expect(interpret([ Apply::Recipe::Op::Goto.new(url_template: '{entry_url}') ])).to eq([ goto ])
  end

  it 'clears a stale form root: only a WaitFor of this run sets it' do
    ctx.form_root = ApplyMate::Client::Browser::Target.css('#old')

    interpret([ goto ])

    expect(ctx.form_root).to be_nil
  end

  it 'parses every op before the first action (an invalid stored recipe touches nothing)' do
    expect { interpret([ goto, { 'op' => 'fill', 'target' => apply_link.to_h } ]) }.to raise_error(ArgumentError, /unknown recipe op/)
    expect(session.calls_of(:goto)).to be_empty
  end

  it 'stops a fenced run before the next op' do
    session.on(:goto) { ctx.fence! }

    expect { interpret([ goto, click ]) }.to raise_error(Apply::Operation::Engine::Fenced)
    expect(session.calls_of(:click)).to be_empty
  end

  context 'when a target of the recipe is gone (a stale locator)' do
    let(:missing) { [ 'a.apply' ] }

    it 'raises Drift for that op, not Halt(:target_not_found)' do
      expect { interpret([ goto, click, wait_for ]) }.to raise_error(Apply::Operation::Recipe::Drift) { |drift|
        expect(drift.op.to_h).to eq(click)
        expect(drift.detail).to match(/no strategy matched/)
      }
      expect(session.calls_of(:ready?)).to be_empty
    end
  end

  context 'when the WaitFor root holds an e-mail-only form (a newsletter box)' do
    let(:form_page) do
      build_snapshot(frames: [ { url: job } ], elements: [ snapshot_element(name: 'Email', type: 'email', regions: [ 'form#apply' ]) ])
    end

    it 'raises Drift for the WaitFor after R2 (AssessFormLikeness) rejects it and clears the root' do
      expect { interpret([ goto, wait_for ]) }.to raise_error(Apply::Operation::Recipe::Drift) { |drift|
        expect(drift.op.to_h).to eq(wait_for)
        expect(drift.detail).to eq('not an application form (too_few_fields)')
        expect(drift.performed).to eq([ goto, wait_for ])
      }
      expect(ctx.form_root).to be_nil
      expect(ctx.scratch.trace.find { |entry| entry['event'] == 'form_likeness' }).to include('accepted' => false)
    end
  end

  context 'when the WaitFor root never gets ready' do
    let(:missing) { [ 'form#apply' ] }

    it 'raises Drift for the WaitFor' do
      expect { interpret([ goto, wait_for ]) }.to raise_error(Apply::Operation::Recipe::Drift) { |drift|
        expect(drift.op.to_h).to eq(wait_for)
      }
      expect(ctx.form_root).to be_nil
    end
  end

  context 'when the click opens a new tab' do
    before { session.on(:click) { session.open_page(form) } }

    it 'switches to it, records a switch_tab op and observes the new page as a navigation' do
      expect(interpret([ goto, click, wait_for ])).to eq([ goto, click, { 'op' => 'switch_tab', 'index' => 1 }, wait_for ])

      expect(session.calls_of(:switch_to)).to eq([ [ 1 ] ])
      expect(ctx.session.current_url).to eq(form)
      expect(ctx.form_url).to eq(form)
      expect(recipe_trace('op')).to eq(%w[goto click switch_tab wait_for])
      expect(ctx.scratch.trace.find { |entry| entry['event'] == 'new_tab' }).to include('index' => 1, 'url' => form)
    end

    it 'waits for the tab only when the probe says the target opens one' do
      interpret([ goto, click ])
      expect(session.calls_of(:wait_until).size).to eq(1) # SwitchTab's own wait, the tab is already there

      allow(session).to receive(:probe).with(:opens_tab, apply_link).and_return(true)
      interpret([ goto, click ])
      expect(session.calls_of(:wait_until).last).to eq([ { timeout: Apply::Recipe::Op::SwitchTab::OPEN_TIMEOUT } ])
      expect(session.calls_of(:wait_until).size).to eq(3)
    end

    it 'keeps a stored switch_tab instead of inserting a second one (replays do not grow)' do
      stored = [ goto, click, { 'op' => 'switch_tab', 'index' => 1 }, wait_for ]

      expect(interpret(stored)).to eq(stored)
      expect(session.calls_of(:switch_to)).to eq([ [ 1 ] ])
    end

    context 'when the tab is a sign-in page' do
      let(:form) { 'https://accounts.google.com/o/oauth2/auth?client_id=1' }

      it 'halts login_required before moving onto it' do
        expect { interpret([ goto, click, wait_for ]) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
          expect(halt).to have_attributes(code: :login_required, detail: 'accounts.google.com/o/oauth2/auth')
        }
        expect(session.calls_of(:switch_to)).to be_empty
      end
    end
  end

  it 'goes on without a tab when the probe expected one but none opened (the link reused a named window)' do
    allow(session).to receive(:probe).with(:opens_tab, apply_link).and_return(true)

    expect(interpret([ goto, click ])).to eq([ goto, click ])
    expect(session.calls_of(:switch_to)).to be_empty
  end

  it 'does not look for new tabs after a navigation (a popup on load never takes the session)' do
    session.on(:goto) { session.open_page(form) }

    expect(interpret([ goto ])).to eq([ goto ])
    expect(session.calls_of(:switch_to)).to be_empty
  end

  it 'stops on a gate after an op (Google Forms)' do
    snapshot = FakeSession::EMPTY_SNAPSHOT.with(evidence: FakeSession::EMPTY_SNAPSHOT.evidence.merge(
      frame_urls: [ 'https://docs.google.com/forms/d/e/1/viewform' ]
    ))
    allow(session).to receive(:snapshot_all).and_return(snapshot)

    expect { interpret([ goto, click ]) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
      expect(halt).to have_attributes(code: :manual_apply_required, detail: :google_forms)
    }
    expect(session.calls_of(:click)).to be_empty
  end
end
