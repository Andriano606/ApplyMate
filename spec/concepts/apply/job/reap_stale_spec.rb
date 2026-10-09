# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Job::ReapStale, type: :job do
  it 'runs on the default queue with a single-run concurrency key' do
    job = described_class.new

    expect(job.queue_name).to eq('default')
    expect(job.concurrency_key).to eq('Apply::Job::ReapStale/apply_reap_stale')
    expect(job.concurrency_limit).to eq(1)
    expect(job.concurrency_duration).to eq(10.minutes)
  end

  it 'runs the ReapStale operation' do
    allow(Apply::Operation::Engine::ReapStale).to receive(:call)

    described_class.new.perform

    expect(Apply::Operation::Engine::ReapStale).to have_received(:call)
  end

  it 'swallows and reports an operation error' do
    allow(Apply::Operation::Engine::ReapStale).to receive(:call).and_raise(StandardError, 'db down')
    allow(Rails.error).to receive(:report)

    expect { described_class.new.perform }.not_to raise_error
    expect(Rails.error).to have_received(:report).with(an_instance_of(StandardError), handled: true)
  end
end
