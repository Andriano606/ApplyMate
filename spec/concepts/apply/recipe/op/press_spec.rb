# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Recipe::Op::Press do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:target) { ApplyMate::Client::Browser::Target.css('[role=tab]', nth: 1) }
  let(:session) { FakeSession.new(html: '', final_url: 'https://acme.example/jobs/1') }

  before { ctx.open_scope!(:survey, session, 5.minutes.from_now) }

  it 'round-trips through its hash' do
    hash = { 'op' => 'press', 'target' => target.to_h, 'key' => 'Enter' }

    expect(Apply::Recipe::Op::Base.parse!(JSON.parse(hash.to_json)).to_h).to eq(hash)
  end

  it 'accepts only the closed key vocabulary (no typing)' do
    expect(described_class::KEYS).to eq(%w[ArrowDown Enter Escape Tab])
    expect { described_class.new(target:, key: 'x') }.to raise_error(ArgumentError, /key "x"/)
    expect { described_class.new(target:, key: 'Control+A') }.to raise_error(ArgumentError)
  end

  it 'runs the gates, presses the key and settles for a key' do
    described_class.new(target:, key: 'ArrowDown').perform!(ctx)

    expect(session.calls.map(&:first)).to eq(%i[snapshot_all press settle])
    expect(session.calls_of(:press)).to eq([ [ target, 'ArrowDown' ] ])
    expect(session.calls_of(:settle)).to eq([ [ :key ] ])
  end
end
