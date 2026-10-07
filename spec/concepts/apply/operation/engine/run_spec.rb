# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::Run, type: :job do
  let(:apply) { create(:apply) }
  let(:handler) { ApplyEngineFakes::Handler.new(apply:) }

  before { allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast) }

  def run
    described_class.call(apply:, handler:)
    apply.reload
  end

  def halt(code, **)
    Apply::Operation::Engine::Halt.new(code, **)
  end

  def steps
    apply.apply_steps.chronological
  end

  context 'when every step succeeds' do
    let(:seen) { {} }

    before do
      allow(ApplyEngineFakes::PrepareStep).to receive(:observe) { |ctx| seen[:prepare] = Apply.find(ctx.apply.id).stage }
      allow(ApplyEngineFakes::SubmitStep).to receive(:observe) do |ctx, **options|
        seen[:submit] = Apply.find(ctx.apply.id).stage
        seen[:options] = options
      end
    end

    it 'records one succeeded ApplyStep per step for attempt 1' do
      run

      expect(steps.map { |s| [ s.attempt, s.key, s.stage, s.position, s.state ] }).to eq(
        [ [ 1, 'fake_prepare', 'fake_prepare', 0, 'succeeded' ], [ 1, 'fake_submit', 'fake_submit', 1, 'succeeded' ] ]
      )
      expect(steps.map(&:finished_at)).to all(be_present)
    end

    it 'sets applies.stage during each step and forwards add_step options' do
      run

      expect(seen).to eq(prepare: 'fake_prepare', submit: 'fake_submit', options: { label: 'fake' })
    end

    it 'ends completed, submitted by the engine, with no stage' do
      run

      expect(apply).to be_completed
      expect(apply.submitted_at).to be_present
      expect(apply.submitted_via).to eq('engine')
      expect(apply.stage).to be_nil
      expect(apply.attempt).to eq(1)
    end

    it 'broadcasts each stage and the final state' do
      run

      expect(Apply::TurboHandler::StatusUpdate).to have_received(:broadcast).exactly(3).times
    end

    it 'shuts the heartbeat ticker down' do
      ticker = Concurrent::TimerTask.new(execution_interval: 30) { nil }
      allow(Apply::Operation::Engine::Heartbeat).to receive(:call)
        .and_return(instance_double(ApplyMate::Operation::Result, model: ticker))
      allow(ticker).to receive(:shutdown)

      run

      expect(ticker).to have_received(:shutdown)
    end
  end

  it 'skips a step whose if: condition is falsy for the context' do
    stub_const('ConditionalHandler', Class.new(Apply::Handler::Base))
    ConditionalHandler.add_step(ApplyEngineFakes::PrepareStep, if: ->(ctx) { ctx.apply.external? })
    ConditionalHandler.add_step(ApplyEngineFakes::SubmitStep, if: ->(ctx) { ctx.attempt == 1 })

    described_class.call(apply:, handler: ConditionalHandler.new(apply:))

    expect(steps.map(&:key)).to eq([ 'fake_submit' ])
    expect(apply.reload).to be_completed
  end

  context 'when a step halts before the claim' do
    before do
      allow(ApplyEngineFakes::SubmitStep).to receive(:observe).and_raise(halt(:no_application_path, detail: 'no reply'))
    end

    it 'records the halt state and a failed ApplyStep with the code' do
      run

      expect(apply).to be_unsupported
      expect(apply.failure).to include('code' => 'no_application_path', 'stage' => 'fake_submit', 'after_claim' => false)
      expect(steps.map(&:state)).to eq(%w[succeeded failed])
      expect(steps.last).to have_attributes(error_code: 'no_application_path', error_detail: 'no reply')
      expect(steps.last.finished_at).to be_present
    end
  end

  context 'when a step raises an unexpected error' do
    before do
      allow(ApplyEngineFakes::PrepareStep).to receive(:observe) { raise ArgumentError, "bad value for #{apply.user.email}" }
      allow(Rails.error).to receive(:report)
    end

    it 'fails with unexpected_error and a redacted detail' do
      run

      expect(apply).to be_failed
      expect(apply.failure).to include('code' => 'unexpected_error', 'kind' => 'permanent',
                                       'detail' => 'ArgumentError: bad value for {{fact.email}}')
      expect(steps.sole).to have_attributes(state: 'failed', error_code: 'unexpected_error',
                                            error_detail: 'ArgumentError: bad value for {{fact.email}}')
      expect(Rails.error).to have_received(:report).with(an_instance_of(ArgumentError), hash_including(:context))
    end
  end

  it 'maps an empty AI response to invalid_ai_output' do
    allow(ApplyEngineFakes::PrepareStep).to receive(:observe).and_raise(ApplyMate::Ai::Client::Base::EmptyResponse, 'empty')

    expect(run.failure).to include('code' => 'invalid_ai_output')
    expect(apply).to be_failed
  end

  it 'maps a failed step result to invalid_record with its messages' do
    allow(ApplyEngineFakes::PrepareStep).to receive(:observe) do |ctx|
      ctx.apply.errors.add(:base, 'Form has no inputs')
      raise ActiveRecord::RecordInvalid, ctx.apply
    end

    expect(run).to be_failed
    expect(apply.failure).to include('code' => 'invalid_record', 'detail' => 'Form has no inputs')
    expect(steps.sole.error_code).to eq('invalid_record')
  end

  describe 'auto-resume of a transient halt' do
    before { allow(ApplyEngineFakes::PrepareStep).to receive(:observe).and_raise(halt(:worker_lost)) }

    it 're-queues once, then stays failed' do
      expect { run }.to have_enqueued_job(Apply::Job::Apply).with(apply.id).exactly(:once)
      expect(apply).to be_queued
      expect(apply.failure).to include('code' => 'worker_lost', 'auto_resumed' => true)

      expect { run }.not_to have_enqueued_job(Apply::Job::Apply)
      expect(apply).to be_failed
      expect(apply.attempt).to eq(2)
      expect(apply.failure).to include('code' => 'worker_lost', 'auto_resumed' => true, 'attempt' => 2)
    end
  end

  it 'halts with deadline before the next step once the run is out of time' do
    allow(ApplyEngineFakes::PrepareStep).to receive(:observe) { travel(Apply::RUN_DEADLINE + 1.minute) }

    run
    travel_back

    expect(apply.failure).to include('code' => 'deadline', 'stage' => 'fake_prepare')
    expect(steps.map(&:key)).to eq([ 'fake_prepare' ])
  end

  describe 'claim rule' do
    it 'records submit_unverified and keeps the claim when the submit step halts after claiming' do
      allow(ApplyEngineFakes::SubmitStep).to receive(:observe) do |ctx|
        Apply::Operation::Engine::ClaimSubmit.call(ctx:)
        raise halt(:validation_rejected)
      end

      run

      expect(apply).to be_submit_unverified
      expect(apply).to be_claimed
      expect(apply.failure).to include('code' => 'validation_rejected', 'after_claim' => true)
    end

    it 'records failed and releases the claim for a definitive rejection' do
      allow(ApplyEngineFakes::SubmitStep).to receive(:observe) do |ctx|
        Apply::Operation::Engine::ClaimSubmit.call(ctx:)
        raise halt(:validation_rejected, definitive: true)
      end

      run

      expect(apply).to be_failed
      expect(apply.submit_claimed_at).to be_nil
    end

    it 'records submit_unverified when the step claims twice' do
      allow(ApplyEngineFakes::SubmitStep).to receive(:observe) do |ctx|
        2.times { Apply::Operation::Engine::ClaimSubmit.call(ctx:) }
      end

      run

      expect(apply).to be_submit_unverified
      expect(apply.failure).to include('code' => 'already_claimed')
    end
  end

  describe 'fencing' do
    it 'writes nothing further once another run rotated the token (zombie)' do
      allow(ApplyEngineFakes::PrepareStep).to receive(:observe) do |ctx|
        rotate_run_token!(ctx.apply)
        Apply.where(id: ctx.apply.id).update_all(state: Apply.states[:running], stage: 'other_run')
      end

      run

      expect(apply).to be_running
      expect(apply.stage).to eq('other_run')
      expect(apply.failure).to be_nil
      expect(steps.map(&:key)).to eq([ 'fake_prepare' ])
    end

    it 'stops before the next step once the heartbeat fenced the context' do
      allow(ApplyEngineFakes::PrepareStep).to receive(:observe) { |ctx| ctx.fence! }

      run

      expect(apply).to be_running
      expect(apply.stage).to eq('fake_prepare')
      expect(steps.map(&:key)).to eq([ 'fake_prepare' ])
    end
  end

  it 'writes nothing when another live run owns the apply' do
    Apply.where(id: apply.id).update_all(state: Apply.states[:running], heartbeat_at: Time.current,
                                         run_token: SecureRandom.uuid, attempt: 1)

    expect { run }.not_to raise_error
    expect(apply).to be_running
    expect(apply.attempt).to eq(1)
    expect(steps).to be_empty
  end
end
