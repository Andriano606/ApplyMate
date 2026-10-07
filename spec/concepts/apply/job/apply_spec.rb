# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Job::Apply, type: :job do
  it 'runs on the apply queue' do
    expect(described_class.new(42).queue_name).to eq('apply')
  end

  it 'limits concurrency to one run per Apply for 45 minutes' do
    job = described_class.new(42)

    expect(job.concurrency_key).to eq('Apply::Job::Apply/apply:42')
    expect(job.concurrency_limit).to eq(1)
    expect(job.concurrency_duration).to eq(45.minutes)
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
end
