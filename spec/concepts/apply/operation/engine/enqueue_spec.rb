# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::Enqueue, type: :job do
  let(:apply) { create(:apply) }

  it 'enqueues Apply::Job::Apply on the apply queue and stores the job id' do
    job = nil

    expect { job = described_class.call(apply:).model }
      .to have_enqueued_job(Apply::Job::Apply).with(apply.id).on_queue('apply')
    expect(apply.reload.job_id).to eq(job.job_id)
  end
end
