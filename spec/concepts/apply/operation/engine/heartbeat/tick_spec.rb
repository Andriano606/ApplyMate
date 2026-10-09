# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::Heartbeat::Tick do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }

  it 'writes heartbeat_at for the owning run' do
    ctx
    Apply.where(id: apply.id).update_all(heartbeat_at: 1.minute.ago)

    expect(described_class.call(ctx:).model).to be(true)
    expect(apply.reload.heartbeat_at).to be_within(5.seconds).of(Time.current)
    expect(ctx).not_to be_fenced
  end

  it 'returns false and fences the context when the token rotated' do
    ctx
    rotate_run_token!(apply)

    expect(described_class.call(ctx:).model).to be(false)
    expect(ctx).to be_fenced
  end

  it 'stops beating past deadline + grace and fences the run (the reaper takes over)' do
    ctx
    Apply.where(id: apply.id).update_all(deadline_at: (Apply::HEARTBEAT_GRACE + 1.minute).ago, heartbeat_at: 1.hour.ago)

    expect(described_class.call(ctx:).model).to be(false)
    expect(ctx).to be_fenced
    expect(apply.reload.heartbeat_at).to be < 30.minutes.ago
  end

  it 'still beats past the deadline but within the grace' do
    ctx
    Apply.where(id: apply.id).update_all(deadline_at: 1.minute.ago)

    expect(described_class.call(ctx:).model).to be(true)
  end
end
