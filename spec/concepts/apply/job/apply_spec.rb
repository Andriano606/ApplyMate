# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Job::Apply, type: :job do
  it 'runs on the apply queue' do
    expect(described_class.new(42).queue_name).to eq('apply')
  end

  it 'limits concurrency to one run per Apply for the longest possible run plus slack' do
    job = described_class.new(42)

    expect(job.concurrency_key).to eq('Apply::Job::Apply/apply:42')
    expect(job.concurrency_limit).to eq(1)
    expect(job.concurrency_duration).to eq(Apply::Operation::Engine::StartContext.max_run_seconds.seconds + described_class::CONCURRENCY_SLACK)
  end

  it 'enqueues on the apply queue' do
    expect { described_class.perform_later(42) }
      .to have_enqueued_job(described_class).with(42).on_queue('apply')
  end

  describe '#perform' do
    let(:apply) { create(:apply) }

    before { allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast) }

    it 'runs the handler resolved for the apply' do
      allow(Apply::Handler::Base).to receive(:for).and_return(ApplyEngineFakes::Handler.new(apply:))

      described_class.perform_now(apply.id)

      expect(apply.reload).to be_completed
    end

    it 'returns normally when another live run owns the apply (NotStartable)' do
      allow(Apply::Handler::Base).to receive(:for).and_return(ApplyEngineFakes::Handler.new(apply:))
      Apply.where(id: apply.id).update_all(state: Apply.states[:running], heartbeat_at: Time.current,
                                           run_token: SecureRandom.uuid)

      expect { described_class.perform_now(apply.id) }.not_to raise_error
      expect(apply.reload).to be_running
      expect(apply.failure).to be_nil
    end

    it 'ignores a deleted apply' do
      expect { described_class.perform_now(0) }.not_to raise_error
    end

    it 'marks a queued apply failed via HaltUnowned when the handler cannot be resolved, and re-raises' do
      apply.source_profile.source.update_columns(scraper: 'ApplyMate::Scraper::Nope')

      expect { described_class.perform_now(apply.id) }.to raise_error(RuntimeError, /No handler defined/)
      expect(apply.reload).to be_failed
      expect(apply.failure).to include('code' => 'unexpected_error', 'detail' => 'RuntimeError')
    end

    it 'leaves a running apply untouched when a pre-run error reaches the job' do
      running = create(:apply, :running)
      allow(Apply::Handler::Base).to receive(:for).and_raise('boom')

      expect { described_class.perform_now(running.id) }.to raise_error(RuntimeError, 'boom')
      expect(running.reload).to be_running
      expect(running.failure).to be_nil
    end
  end

  describe 'capacity retries' do
    let(:apply) { create(:apply) }
    let(:handler) { ApplyEngineFakes::Handler.new(apply:) }

    before do
      allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast)
      allow(Apply::Handler::Base).to receive(:for).and_return(handler)
      allow(ApplyEngineFakes::PrepareStep).to receive(:observe).and_raise(ApplyMate::Client::Browser::PoolBusy, 'busy')
    end

    it 're-enqueues the job with a wait and leaves the row waiting_capacity' do
      expect { described_class.perform_now(apply.id) }.to have_enqueued_job(described_class).with(apply.id)

      expect(apply.reload).to be_waiting_capacity
      expect(apply.failure).to be_nil
    end

    it 'starts the waiting_capacity row again on the retry' do
      described_class.perform_now(apply.id)
      allow(ApplyEngineFakes::PrepareStep).to receive(:observe)

      described_class.perform_now(apply.id)

      expect(apply.reload).to be_completed
      expect(apply.attempt).to eq(2)
    end

    it 'records failed(:capacity) through HaltUnowned once the retries are exhausted' do
      job = described_class.new(apply.id)
      (described_class::MAX_CAPACITY_RETRIES - 1).times { job.perform_now }
      expect(apply.reload).to be_waiting_capacity

      expect { job.perform_now }.not_to have_enqueued_job(described_class)
      expect(apply.reload).to be_failed
      expect(apply.failure).to include('code' => 'capacity', 'kind' => 'transient')
      expect(apply.failure['code']).not_to eq('unexpected_error')
    end
  end

  describe 'host slot throttling' do
    let(:apply) { create(:apply) }
    let(:handler) { ApplyEngineFakes::Handler.new(apply:) }
    let(:until_time) { 15.minutes.from_now.change(usec: 0) }

    before do
      allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast)
      allow(Apply::Handler::Base).to receive(:for).and_return(handler)
      allow(ApplyEngineFakes::PrepareStep).to receive(:observe)
        .and_raise(Apply::Operation::Engine::Throttled.new(until: until_time))
    end

    it 'retries the job at the slot time and leaves the row waiting_capacity' do
      expect { described_class.perform_now(apply.id) }.to have_enqueued_job(described_class).with(apply.id).at(until_time)

      expect(apply.reload).to be_waiting_capacity
      expect(apply.failure).to be_nil
    end

    it 'records failed(:capacity) through HaltUnowned after MAX_THROTTLE_WAITS runs' do
      job = described_class.new(apply.id)
      (described_class::MAX_THROTTLE_WAITS - 1).times { job.perform_now }
      expect(apply.reload).to be_waiting_capacity

      expect { job.perform_now }.not_to have_enqueued_job(described_class)
      expect(apply.reload).to be_failed
      expect(apply.failure).to include('code' => 'capacity', 'kind' => 'transient')
    end

    it 'counts throttle waits apart from the PoolBusy retries of the same job' do
      job = described_class.new(apply.id)
      job.executions = described_class::MAX_CAPACITY_RETRIES + described_class::MAX_THROTTLE_WAITS

      expect { job.perform_now }.to have_enqueued_job(described_class).with(apply.id).at(until_time)
      expect(apply.reload).to be_waiting_capacity
      expect(job.exception_executions).to eq(described_class::THROTTLE_WAITS_KEY => 1)
    end

    it 'never turns a throttle into unexpected_error' do
      described_class.perform_now(apply.id)

      expect(apply.reload.failure).to be_nil
    end
  end
end
