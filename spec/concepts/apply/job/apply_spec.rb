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
end
