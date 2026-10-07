# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::Context do
  let(:apply) { build(:apply, stage: 'fake_prepare') }
  let(:ctx) do
    described_class.new(apply:, attempt: 2, run_token: SecureRandom.uuid, deadline_at: 10.minutes.from_now,
                        fence_flag: Concurrent::AtomicBoolean.new(false))
  end

  it 'reports the seconds left until the deadline' do
    freeze_time do
      expect(ctx.remaining).to be_within(0.001).of(600.0)
    end
  end

  it 'is negative once the deadline passed' do
    ctx
    travel_to(11.minutes.from_now) do
      expect(ctx.remaining).to be < 0
    end
  end

  it 'reads the current stage from the apply' do
    expect(ctx.current_stage).to eq('fake_prepare')
  end

  it 'fences through the shared flag' do
    expect { ctx.check_fence! }.not_to raise_error

    ctx.fence!

    expect(ctx).to be_fenced
    expect { ctx.check_fence! }.to raise_error(Apply::Operation::Engine::Fenced)
  end

  it 'shares the flag between copies (the heartbeat thread holds the same object)' do
    copy = ctx.with(attempt: 3)
    ctx.fence!

    expect(copy).to be_fenced
  end
end
