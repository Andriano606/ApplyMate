# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::GuardAction do
  let(:ctx) { engine_context(create(:apply)) }

  def obstructed
    ApplyMate::Client::Browser::Obstructed.new('locator(#continue)', 'intercepts pointer events')
  end

  context 'with a scripted session' do
    let(:session) { FakeSession.new(html: '', final_url: 'https://jobs.example.com/apply') }
    let(:outcomes) { [] }
    let(:action) do
      lambda do
        session.click(ApplyMate::Client::Browser::Target.css('#continue'))
        outcome = outcomes.shift
        raise outcome if outcome

        :clicked
      end
    end

    before { ctx.open_scope!(:survey, session, 5.minutes.from_now) }

    it 'runs the after_action gates on a fresh snapshot before the action' do
      expect(described_class.call(ctx:, action:).model).to eq(:clicked)
      expect(session.calls.map(&:first)).to eq(%i[snapshot_all click])
    end

    it 'runs the gates again and retries once after an obstruction' do
      outcomes << obstructed

      expect(described_class.call(ctx:, action:).model).to eq(:clicked)
      expect(session.calls.map(&:first)).to eq(%i[snapshot_all click snapshot_all click])
      expect(ctx.scratch.trace.last).to include('event' => 'obstructed', 'retry' => true)
    end

    it 'halts target_obstructed on the second obstruction' do
      outcomes.push(obstructed, obstructed)

      expect { described_class.call(ctx:, action:) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :target_obstructed, detail: 'intercepts pointer events')
      }
      expect(session.calls_of(:click).size).to eq(2)
    end

    it 'never acts when a gate stops the run' do
      snapshot = FakeSession::EMPTY_SNAPSHOT.with(frames: [ { 'ref' => 'f0', 'captcha' => [ 'hcaptcha' ] } ])
      allow(session).to receive(:snapshot_all).and_return(snapshot)

      expect { described_class.call(ctx:, action:) }.to raise_error(Apply::Operation::Engine::Halt, /manual_apply_required/)
      expect(session.calls_of(:click)).to be_empty
    end

    it 'lets other errors through without a retry' do
      outcomes << ApplyMate::Client::Browser::TargetNotFound.new(ApplyMate::Client::Browser::Target.css('#continue'))

      expect { described_class.call(ctx:, action:) }.to raise_error(ApplyMate::Client::Browser::TargetNotFound)
      expect(session.calls_of(:click).size).to eq(1)
    end
  end

  # widgets.html: #cookie-overlay covers the page 3 s after load and intercepts every click until "Accept".
  context 'with the delayed cookie overlay', :browser do
    let(:overlay) { ApplyMate::Client::Browser::Target.css('#cookie-overlay') }
    let(:continue) { ApplyMate::Client::Browser::Target.css('#continue') }

    before { stub_const('ApplyMate::Client::Browser::Driver::Playwright::ACTION_TIMEOUT_MS', 2_000) }

    # The first attempt waits for the overlay AFTER the gates ran (so they could not see it) and is obstructed.
    def click_continue(session)
      attempts = 0
      lambda do
        attempts += 1
        session.wait_until(timeout: 6) { session.present?(overlay, visibility: :required) } if attempts == 1
        session.click(continue)
        attempts
      end
    end

    it 'clicks the banner away through CookieConsent and retries once' do
      in_fixture_scope(ctx) do |session|
        session.goto(FixtureSite.url('/widgets.html'))

        expect(described_class.call(ctx:, action: click_continue(session)).model).to eq(2)
        expect(ctx.scratch.consent_clicks).to eq(1)
        expect(session.present?(overlay, visibility: :attached)).to be(false)
      end
    end

    it 'halts target_obstructed when the second attempt is obstructed too' do
      in_fixture_scope(ctx) do |session|
        session.goto(FixtureSite.url('/widgets.html'))
        ctx.scratch.consent_clicks = Apply::Gate::CookieConsent::MAX_CLICKS # the gate may not click any more

        expect { described_class.call(ctx:, action: click_continue(session)) }
          .to raise_error(Apply::Operation::Engine::Halt) { |halt|
            expect(halt).to have_attributes(code: :target_obstructed, detail: 'intercepts pointer events')
          }
      end
    end
  end
end
