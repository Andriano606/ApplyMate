# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Recipe::Op::SwitchTab do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:job) { 'https://acme.example/jobs/1' }
  let(:form) { 'https://acme.example/jobs/1/apply' }
  let(:session) { FakeSession.new(html: '', final_url: job, pages: [ job, form ]) }

  before { ctx.open_scope!(:survey, session, 5.minutes.from_now) }

  it 'round-trips through its hash' do
    expect(Apply::Recipe::Op::Base.parse!('op' => 'switch_tab', 'index' => 1).to_h).to eq('op' => 'switch_tab', 'index' => 1)
  end

  it 'moves the session onto the tab and waits for its content' do
    described_class.new(index: 1).perform!(ctx)

    expect(session.calls).to eq([ [ :wait_until, { timeout: described_class::OPEN_TIMEOUT } ], [ :pages ], [ :switch_to, 1 ],
                                  [ :settle_content ] ])
    expect(session.current_url).to eq(form)
  end

  it 'waits for the tab at most OPEN_TIMEOUT, clamped to the time left' do
    ctx.scratch.scope_deadline = 3.seconds.from_now
    described_class.new(index: 1).perform!(ctx)

    expect(session.calls_of(:wait_until).sole.sole[:timeout]).to be <= 3
  end

  it 'is drift when the tab never opens' do
    op = described_class.new(index: 2)

    expect { op.perform!(ctx) }.to raise_error(Apply::Operation::Recipe::Drift) { |drift|
      expect(drift).to have_attributes(op:, detail: 'tab 2 never opened')
    }
    expect(session.calls_of(:switch_to)).to be_empty
  end

  context 'when the tab is a sign-in page' do
    let(:form) { 'https://www.linkedin.com/oauth/v2/authorization?client_id=1' }

    it 'halts login_required before moving onto it' do
      expect { described_class.new(index: 1).perform!(ctx) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :login_required, detail: 'linkedin.com/oauth/v2/authorization')
      }
      expect(session.calls_of(:switch_to)).to be_empty
    end
  end
end
