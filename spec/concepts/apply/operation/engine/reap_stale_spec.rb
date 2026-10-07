# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::ReapStale, type: :job do
  before { allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast) }

  def stale_apply(**attrs)
    create(:apply, :running, heartbeat_at: 10.minutes.ago, job_id: SecureRandom.uuid, **attrs)
  end

  def solid_job(apply)
    SolidQueue::Job.create!(queue_name: 'apply', class_name: 'Apply::Job::Apply', active_job_id: apply.job_id, arguments: {})
  end

  # A job executing on a worker process whose last heartbeat was `beat_ago` ago.
  def executing_job(apply, beat_ago: 10.seconds)
    job = solid_job(apply)
    job.ready_execution.destroy!
    process = SolidQueue::Process.create!(kind: 'Worker', name: SecureRandom.hex(4), pid: 1, hostname: 'spec',
                                          last_heartbeat_at: beat_ago.ago)
    SolidQueue::ClaimedExecution.create!(job:, process:)
    job
  end

  def reap
    described_class.call.model
  end

  context 'when no job exists behind a running apply' do
    let!(:apply) { stale_apply }

    it 'records worker_lost, rotates the run_token and auto-resumes once' do
      old_token = apply.run_token

      expect(reap).to eq(reaped: 0, resumed: 1, alive: 0)

      apply.reload
      expect(apply).to be_queued
      expect(apply.run_token).not_to eq(old_token)
      expect(apply.stage).to be_nil
      expect(apply.failure).to include('code' => 'worker_lost', 'kind' => 'transient', 'auto_resumed' => true)
      expect(Apply::Job::Apply).to have_been_enqueued.with(apply.id)
      expect(apply.job_id).to be_present
      expect(Apply::TurboHandler::StatusUpdate).to have_received(:broadcast)
    end

    it 'fails the apply when it was already auto-resumed, without enqueueing' do
      apply.update!(failure: { code: 'worker_lost', auto_resumed: true })

      expect(reap).to eq(reaped: 1, resumed: 0, alive: 0)

      expect(apply.reload).to be_failed
      expect(apply.failure).to include('code' => 'worker_lost', 'auto_resumed' => true)
      expect(Apply::Job::Apply).not_to have_been_enqueued
    end

    it 'touches users.applies_changed_at for the navbar counter' do
      expect { reap }.to(change { apply.user.reload.applies_changed_at })
    end
  end

  it "fails the reaped attempt's step rows left running, so the timeline stops spinning and pruning can match them" do
    apply = stale_apply(failure: { auto_resumed: true })
    open = ApplyStep.create!(apply:, attempt: apply.attempt, key: 'generate_cv', stage: 'generate_cv', position: 0,
                             state: :running, started_at: 20.minutes.ago)

    reap

    expect(open.reload).to have_attributes(state: 'failed', error_code: 'worker_lost', finished_at: be_present)
  end

  it 'leaves a run that finished between the candidate SELECT and the UPDATE alone' do
    apply = stale_apply
    allow(SolidQueue::Job).to receive(:where).and_wrap_original do |original, *args, **kwargs|
      # The run completes (Finish keeps run_token) right after the reaper read the row.
      Apply.where(id: apply.id).update_all(state: Apply.states[:completed], submitted_at: Time.current)
      original.call(*args, **kwargs)
    end

    expect(reap).to eq(reaped: 0, resumed: 0, alive: 0)

    expect(apply.reload).to be_completed
    expect(apply.failure).to be_nil
    expect(Apply::Job::Apply).not_to have_been_enqueued
  end

  it 'closes a claimed run as submit_unverified, never auto-resuming' do
    apply = stale_apply(submit_claimed_at: 5.minutes.ago)

    expect(reap).to eq(reaped: 1, resumed: 0, alive: 0)

    expect(apply.reload).to be_submit_unverified
    expect(apply.submit_claimed_at).to be_present
    expect(apply.failure).to include('after_claim' => true)
    expect(Apply::Job::Apply).not_to have_been_enqueued
  end

  it 'leaves an apply whose job waits in the ready queue untouched' do
    apply = stale_apply
    solid_job(apply)

    expect(reap).to eq(reaped: 0, resumed: 0, alive: 1)
    expect(apply.reload).to be_running
  end

  it 'leaves an apply whose job is scheduled untouched' do
    apply = stale_apply
    SolidQueue::Job.create!(queue_name: 'apply', class_name: 'Apply::Job::Apply', active_job_id: apply.job_id,
                            arguments: {}, scheduled_at: 1.minute.from_now)

    expect(reap[:alive]).to eq(1)
    expect(apply.reload).to be_running
  end

  it 'judges a retried job by its newest row, not the finished row of the earlier execution' do
    apply = stale_apply(state: :waiting_capacity, stage: nil)
    finished = solid_job(apply)
    finished.ready_execution.destroy!
    finished.update!(finished_at: 5.minutes.ago)
    SolidQueue::Job.create!(queue_name: 'apply', class_name: 'Apply::Job::Apply', active_job_id: apply.job_id,
                            arguments: {}, scheduled_at: 10.minutes.from_now)

    expect(reap).to eq(reaped: 0, resumed: 0, alive: 1)
    expect(apply.reload).to be_waiting_capacity
  end

  it 'leaves an apply untouched while a live process executes it within the deadline' do
    apply = stale_apply
    executing_job(apply)

    expect(reap).to eq(reaped: 0, resumed: 0, alive: 1)
    expect(apply.reload).to be_running
  end

  it 'fails with code deadline when the deadline plus grace passed on a live process' do
    apply = stale_apply(deadline_at: (Apply::REAPER_GRACE + 1.minute).ago, failure: { auto_resumed: true })
    executing_job(apply)

    reap

    expect(apply.reload).to be_failed
    expect(apply.failure).to include('code' => 'deadline')
  end

  it 'reaps an apply whose process stopped heartbeating' do
    apply = stale_apply(failure: { auto_resumed: true })
    executing_job(apply, beat_ago: 10.minutes)

    expect(reap[:reaped]).to eq(1)
    expect(apply.reload).to be_failed
  end

  it 'reaps an apply whose job already finished or failed' do
    finished = stale_apply(failure: { auto_resumed: true })
    solid_job(finished).tap { |job| job.ready_execution.destroy! }.update!(finished_at: Time.current)
    failed = stale_apply(failure: { auto_resumed: true })
    job = solid_job(failed)
    job.ready_execution.destroy!
    SolidQueue::FailedExecution.create!(job:, error: { message: 'boom' })

    expect(reap[:reaped]).to eq(2)
  end

  it 'ignores fresh heartbeats and rows that are not in progress' do
    fresh = create(:apply, :running, heartbeat_at: 30.seconds.ago, job_id: SecureRandom.uuid)
    done = create(:apply, :completed)

    expect(reap).to eq(reaped: 0, resumed: 0, alive: 0)
    expect(fresh.reload).to be_running
    expect(done.reload).to be_completed
  end

  it 'fences a zombie run after reaping' do
    apply = stale_apply
    ctx = Apply::Operation::Engine::Context.new(apply:, attempt: 1, run_token: apply.run_token,
                                                deadline_at: apply.deadline_at,
                                                fence_flag: Concurrent::AtomicBoolean.new(false))

    reap

    expect do
      Apply::Operation::Engine::FencedUpdate.call(ctx:, attributes: { stage: 'submit' })
    end.to raise_error(Apply::Operation::Engine::Fenced)
  end

  it 'continues past a row that raises' do
    broken = stale_apply
    good = stale_apply(failure: { auto_resumed: true })
    allow(Rails.error).to receive(:report)
    allow_any_instance_of(Apply).to receive(:claimed?).and_wrap_original do |original|
      raise 'boom' if original.receiver.id == broken.id

      original.call
    end

    reap

    expect(Rails.error).to have_received(:report)
    expect(broken.reload).to be_running
    expect(good.reload).to be_failed
  end

  describe 'termination' do
    it 'reads at most two batches when 150 candidates are all alive' do
      create_list(:apply, 150, :running, heartbeat_at: 10.minutes.ago).each do |apply|
        apply.update_columns(job_id: SecureRandom.uuid)
        solid_job(apply)
      end
      queries = 0
      counter = lambda do |*, payload|
        queries += 1 if payload[:sql].include?('COALESCE(heartbeat_at, updated_at)') && payload[:sql].include?('LIMIT')
      end

      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        expect(described_class.call(batch_size: 100).model).to eq(reaped: 0, resumed: 0, alive: 150)
      end

      expect(queries).to eq(2)
    end

    it 'stops at max_batches' do
      create_list(:apply, 3, :running, heartbeat_at: 10.minutes.ago, failure: { auto_resumed: true })

      expect(described_class.call(batch_size: 1, max_batches: 2).model[:reaped]).to eq(2)
    end
  end
end
