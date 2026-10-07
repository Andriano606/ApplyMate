# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::CloseSteps do
  let(:apply) { create(:apply, :running, attempt: 2) }

  def step(attempt:, key:, state: :running, **attrs)
    ApplyStep.create!(apply:, attempt:, key:, stage: key, position: 0, state:, started_at: 1.hour.ago, **attrs)
  end

  it 'fails the running rows of the given attempts with the code and a finished_at' do
    open = step(attempt: 2, key: 'submit')
    done = step(attempt: 2, key: 'fetch_form', state: :succeeded, finished_at: 2.minutes.ago)
    other_attempt = step(attempt: 1, key: 'submit')

    expect(described_class.call(apply_id: apply.id, attempts: 2, code: :worker_lost).model).to eq(1)

    expect(open.reload).to have_attributes(state: 'failed', error_code: 'worker_lost', finished_at: be_present)
    expect(done.reload).to be_succeeded
    expect(other_attempt.reload).to be_running
  end

  it 'accepts a range of attempts' do
    first = step(attempt: 1, key: 'submit')
    current = step(attempt: 2, key: 'submit')

    described_class.call(apply_id: apply.id, attempts: ...2, code: :worker_lost)

    expect(first.reload).to be_failed
    expect(current.reload).to be_running
  end
end
