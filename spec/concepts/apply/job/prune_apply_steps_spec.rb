# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Job::PruneApplySteps, type: :job do
  it 'runs on the default queue with a single-run concurrency key' do
    job = described_class.new

    expect(job.queue_name).to eq('default')
    expect(job.concurrency_key).to eq('Apply::Job::PruneApplySteps/apply_prune_apply_steps')
    expect(job.concurrency_limit).to eq(1)
    expect(job.concurrency_duration).to eq(1.hour)
  end

  it 'runs the PruneApplySteps operation' do
    allow(Apply::Operation::Engine::PruneApplySteps).to receive(:call)

    described_class.new.perform

    expect(Apply::Operation::Engine::PruneApplySteps).to have_received(:call)
  end
end
