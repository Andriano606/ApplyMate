# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Job::ExpireWaiting, type: :job do
  it 'runs on the default queue with a single-run concurrency key' do
    job = described_class.new

    expect(job.queue_name).to eq('default')
    expect(job.concurrency_key).to eq('Apply::Job::ExpireWaiting/apply_expire_waiting')
    expect(job.concurrency_limit).to eq(1)
    expect(job.concurrency_duration).to eq(30.minutes)
  end

  it 'runs the ExpireWaiting operation' do
    allow(Apply::Operation::Engine::ExpireWaiting).to receive(:call)

    described_class.new.perform

    expect(Apply::Operation::Engine::ExpireWaiting).to have_received(:call)
  end
end
