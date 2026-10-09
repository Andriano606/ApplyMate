# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::Lifecycle::WaitCapacity, type: :job do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:failure) { { 'code' => 'worker_lost', 'auto_resumed' => true } }

  before do
    allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast)
    ctx
    Apply.where(id: apply.id).update_all(stage: 'fake_submit', failure:)
    ApplyStep.create!(apply:, attempt: ctx.attempt, key: 'fake_submit', stage: 'fake_submit', position: 0,
                      state: :running, started_at: Time.current)
  end

  it 'parks the row in waiting_capacity, clears the stage and leaves failure untouched' do
    described_class.call(ctx:)

    expect(apply.reload).to be_waiting_capacity
    expect(apply.stage).to be_nil
    expect(apply.failure).to eq(failure)
  end

  it 'closes the running step rows with capacity' do
    described_class.call(ctx:)

    expect(apply.apply_steps.sole).to have_attributes(state: 'failed', error_code: 'capacity')
    expect(apply.apply_steps.sole.finished_at).to be_present
  end

  it 'touches the user and broadcasts' do
    expect { described_class.call(ctx:) }.to(change { apply.user.reload.applies_changed_at })
    expect(Apply::TurboHandler::StatusUpdate).to have_received(:broadcast).with(apply)
  end

  it 'writes nothing once the run token was rotated' do
    rotate_run_token!(apply)

    expect { described_class.call(ctx:) }.to raise_error(Apply::Operation::Engine::Fenced)
    expect(apply.reload).to be_running
    expect(apply.stage).to eq('fake_submit')
    expect(apply.apply_steps.sole).to be_running
  end
end
