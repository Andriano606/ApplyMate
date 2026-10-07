# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::Lifecycle::Finish do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }

  before do
    allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast)
    ctx
    Apply.where(id: apply.id).update_all(stage: 'fake_submit', failure: { code: 'worker_lost', auto_resumed: true })
  end

  it 'completes the apply as submitted by the engine' do
    freeze_time do
      described_class.call(ctx:)

      apply.reload
      expect(apply).to be_completed
      expect(apply.submitted_at).to eq(Time.current)
      expect(apply.submitted_via).to eq('engine')
      expect(apply.stage).to be_nil
      expect(apply.failure).to be_nil
    end
  end

  it 'keeps a submitted_at the submit step already wrote' do
    submitted_at = 2.minutes.ago.change(usec: 0)
    Apply.where(id: apply.id).update_all(submitted_at:)

    described_class.call(ctx:)

    expect(apply.reload.submitted_at).to eq(submitted_at)
  end

  it 'touches the user and broadcasts' do
    expect { described_class.call(ctx:) }.to(change { apply.user.reload.applies_changed_at })
    expect(Apply::TurboHandler::StatusUpdate).to have_received(:broadcast)
  end

  it 'writes nothing for a zombie run' do
    rotate_run_token!(apply)

    expect { described_class.call(ctx:) }.to raise_error(Apply::Operation::Engine::Fenced)
    expect(apply.reload).to be_running
  end
end
