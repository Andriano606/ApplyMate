# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::Lifecycle::RecordHalt, type: :job do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }

  before do
    allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast)
    ctx
    Apply.where(id: apply.id).update_all(stage: 'fake_submit')
  end

  def record(code, **)
    described_class.call(ctx:, halt: Apply::Operation::Engine::Halt.new(code, **))
    apply.reload
  end

  it 'lands in the halt state with a redacted failure and clears the stage' do
    record(:no_application_path, detail: "no reply button for #{apply.user.email}")

    expect(apply).to be_unsupported
    expect(apply.stage).to be_nil
    expect(apply.failure).to eq('code' => 'no_application_path', 'kind' => 'unsupported', 'stage' => 'fake_submit',
                                'detail' => 'no reply button for {{fact.email}}', 'after_claim' => false,
                                'attempt' => 1)
  end

  it 'touches the user and broadcasts the new state' do
    expect { record(:login_required) }.to(change { apply.user.reload.applies_changed_at })
    expect(Apply::TurboHandler::StatusUpdate).to have_received(:broadcast).with(apply)
  end

  it 'records needs_human for manual_apply_required' do
    expect(record(:manual_apply_required, detail: :google_forms)).to be_needs_human
  end

  describe 'claim rule' do
    before { Apply::Operation::Engine::ClaimSubmit.call(ctx:) }

    it 'turns any halt after the claim into submit_unverified and keeps the claim and code' do
      record(:validation_rejected)

      expect(apply).to be_submit_unverified
      expect(apply).to be_claimed
      expect(apply.failure).to include('code' => 'validation_rejected', 'after_claim' => true)
    end

    it 'releases the claim for a definitive rejection in the same update' do
      record(:validation_rejected, definitive: true)

      expect(apply).to be_failed
      expect(apply.submit_claimed_at).to be_nil
      expect(apply.failure).to include('code' => 'validation_rejected', 'after_claim' => true)
    end

    it 'never auto-resumes a transient halt after the claim' do
      expect { record(:worker_lost) }.not_to have_enqueued_job(Apply::Job::Apply)
      expect(apply).to be_submit_unverified
    end
  end

  describe 'auto-resume' do
    it 're-queues a transient halt before the claim once' do
      expect { record(:worker_lost) }.to have_enqueued_job(Apply::Job::Apply).with(apply.id)

      expect(apply).to be_queued
      expect(apply.failure).to include('code' => 'worker_lost', 'auto_resumed' => true)
      expect(apply.job_id).to be_present
    end

    it 'leaves the second transient halt failed and keeps the flag' do
      record(:worker_lost)
      second = engine_context(apply)

      expect { described_class.call(ctx: second, halt: Apply::Operation::Engine::Halt.new(:deadline)) }
        .not_to have_enqueued_job(Apply::Job::Apply)
      expect(apply.reload).to be_failed
      expect(apply.failure).to include('code' => 'deadline', 'auto_resumed' => true, 'attempt' => 2)
    end

    it 'does not re-queue a permanent halt' do
      expect { record(:unexpected_error) }.not_to have_enqueued_job(Apply::Job::Apply)
      expect(apply).to be_failed
    end
  end

  it "closes this attempt's step rows still marked running" do
    open = ApplyStep.create!(apply:, attempt: ctx.attempt, key: 'fake_submit', stage: 'fake_submit', position: 0,
                             state: :running, started_at: Time.current)

    record(:unexpected_error)

    expect(open.reload).to have_attributes(state: 'failed', error_code: 'unexpected_error', finished_at: be_present)
  end

  it 'writes nothing for a zombie run' do
    rotate_run_token!(apply)

    expect { described_class.call(ctx:, halt: Apply::Operation::Engine::Halt.new(:unexpected_error)) }
      .to raise_error(Apply::Operation::Engine::Fenced)
    expect(apply.reload).to be_running
  end

  it 'survives a failing broadcast' do
    allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast).and_raise('render failed')

    expect(record(:login_required)).to be_unsupported
  end
end
