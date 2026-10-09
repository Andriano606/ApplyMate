# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VacancyCv::Job::Create, type: :job do
  it 'runs on the apply queue' do
    expect(described_class.new(7, 1).queue_name).to eq('apply')
  end

  it 'limits concurrency to one run per VacancyCv for 15 minutes' do
    job = described_class.new(7, 1)

    expect(job.concurrency_key).to eq('VacancyCv::Job::Create/vacancy_cv:7')
    expect(job.concurrency_limit).to eq(1)
    expect(job.concurrency_duration).to eq(15.minutes)
  end

  it 'retries when the local Chrome slot stays taken' do
    allow(VacancyCv).to receive(:includes).and_raise(ApplyMate::Client::LocalChrome::Busy, 'slot taken')

    expect { described_class.perform_now(7, 1) }.to have_enqueued_job(described_class).with(7, 1)
  end

  it 'enqueues on the apply queue' do
    expect { described_class.perform_later(7, 1) }
      .to have_enqueued_job(described_class).with(7, 1).on_queue('apply')
  end
end
