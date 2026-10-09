# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::StartContext do
  subject(:start) { described_class.call(apply:) }

  shared_examples 'a started run' do
    it 'takes the row: running, attempt + 1, fresh run_token, deadline and heartbeat' do
      previous_attempt = apply.attempt
      previous_token = apply.run_token
      ctx = start.model

      apply.reload
      expect(apply).to be_running
      expect(apply.attempt).to eq(previous_attempt + 1)
      expect(apply.run_token).to be_present
      expect(apply.run_token).not_to eq(previous_token)
      expect(apply.stage).to be_nil
      expect(apply.heartbeat_at).to be_present
      expect(apply.deadline_at).to be_within(1.minute).of(Apply::RUN_DEADLINE.from_now)

      expect(ctx.apply).to eq(apply)
      expect(ctx.attempt).to eq(apply.attempt)
      expect(ctx.run_token).to eq(apply.run_token)
      expect(ctx.deadline_at).to eq(apply.deadline_at)
      expect(ctx).not_to be_fenced
    end
  end

  it 'resets the per-attempt AI counter and leaves the lifetime one' do
    apply = create(:apply, state: :waiting_capacity, ai_calls: 12, ai_calls_total: 40)

    described_class.call(apply:)

    expect(apply.reload).to have_attributes(ai_calls: 0, ai_calls_total: 40)
  end

  it 'clears a stale input request and response so a resumed run never consumes an old code' do
    apply = create(:apply, state: :waiting_capacity, input_request: { 'kind' => 'email_code' }, input_response: { 'code' => '123456' })

    described_class.call(apply:)

    expect(apply.reload).to have_attributes(input_request: nil, input_response: nil)
  end

  context 'when queued' do
    let(:apply) { create(:apply) }

    it_behaves_like 'a started run'
  end

  context 'when waiting for capacity' do
    let(:apply) { create(:apply, state: :waiting_capacity, attempt: 2) }

    it_behaves_like 'a started run'
  end

  context 'when running with a stale heartbeat (redelivered job)' do
    let(:apply) { create(:apply, :running, heartbeat_at: (Apply::STALE_AFTER + 1.minute).ago) }

    it_behaves_like 'a started run'
  end

  context 'when taking over a stale run that left a step row running' do
    let(:apply) { create(:apply, :running, heartbeat_at: (Apply::STALE_AFTER + 1.minute).ago) }

    it "fails the earlier attempt's open rows with worker_lost" do
      open = ApplyStep.create!(apply:, attempt: apply.attempt, key: 'generate_cv', stage: 'generate_cv', position: 0,
                               state: :running, started_at: 10.minutes.ago)

      start

      expect(open.reload).to have_attributes(state: 'failed', error_code: 'worker_lost', finished_at: be_present)
    end
  end

  context 'when running with a fresh heartbeat (live run)' do
    let(:apply) { create(:apply, :running, heartbeat_at: 10.seconds.ago) }

    it 'raises NotStartable and leaves the row alone' do
      token = apply.run_token

      expect { start }.to raise_error(Apply::Operation::Engine::NotStartable)
      expect(apply.reload.run_token).to eq(token)
      expect(apply.attempt).to eq(1)
    end
  end

  %i[completed failed needs_human cancelled].each do |state|
    context "when #{state}" do
      let(:apply) { create(:apply, state:) }

      it 'raises NotStartable' do
        expect { start }.to raise_error(Apply::Operation::Engine::NotStartable)
        expect(apply.reload.state).to eq(state.to_s)
      end
    end
  end

  it 'rotates the token on every start' do
    apply = create(:apply)
    first = engine_context(apply)
    Apply.where(id: apply.id).update_all(state: Apply.states[:queued])
    second = engine_context(apply)

    expect(second.attempt).to eq(first.attempt + 1)
    expect(second.run_token).not_to eq(first.run_token)
  end
end
