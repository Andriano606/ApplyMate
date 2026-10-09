# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Recipe::Op::Click do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:target) { ApplyMate::Client::Browser::Target.css('a.apply', has_text: 'Apply') }
  let(:session) { FakeSession.new(html: '', final_url: 'https://acme.example/jobs/1') }
  let(:op) { described_class.new(target:) }

  before { ctx.open_scope!(:survey, session, 5.minutes.from_now) }

  it 'round-trips through its hash' do
    expect(op.to_h).to eq('op' => 'click', 'target' => target.to_h)
    expect(Apply::Recipe::Op::Base.parse!(JSON.parse(op.to_h.to_json)).target).to eq(target)
  end

  it 'runs the after_action gates, clicks and settles for a click' do
    op.perform!(ctx)

    expect(session.calls.map(&:first)).to eq(%i[snapshot_all click settle])
    expect(session.calls_of(:click)).to eq([ [ target ] ])
    expect(session.calls_of(:settle)).to eq([ [ :click ] ])
  end

  it 'retries once when the target is obstructed (Engine::GuardAction)' do
    attempts = 0
    session.on(:click) do |clicked|
      attempts += 1
      raise ApplyMate::Client::Browser::Obstructed.new(clicked, 'intercepts pointer events') if attempts == 1
    end

    op.perform!(ctx)

    expect(session.calls_of(:click).size).to eq(2)
  end

  it 'lets TargetNotFound through (Interpret turns it into drift)' do
    session = FakeSession.new(html: '', final_url: 'about:blank', missing: [ 'a.apply' ])
    ctx.open_scope!(:survey, session, 5.minutes.from_now)

    expect { op.perform!(ctx) }.to raise_error(ApplyMate::Client::Browser::TargetNotFound)
    expect(session.calls_of(:settle)).to be_empty
  end
end
