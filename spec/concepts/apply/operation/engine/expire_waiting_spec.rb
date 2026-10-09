# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::ExpireWaiting do
  before { allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast) }

  def aged(apply, age)
    apply.tap { |record| record.update_columns(updated_at: age.ago) }
  end

  it 'fails needs_human older than 7 days with human_timeout, keeping the previous failure' do
    apply = aged(create(:apply, :needs_human), Apply::HUMAN_TIMEOUT + 1.hour)

    expect(described_class.call.model).to eq(human_timeout: 1, review_expired: 0, reminded: 0)

    apply.reload
    expect(apply).to be_failed
    expect(apply.failure).to include('code' => 'human_timeout', 'kind' => 'permanent', 'expired_at' => be_present)
    expect(apply.failure['previous']).to include('code' => 'manual_apply_required')
    expect(Apply::TurboHandler::StatusUpdate).to have_received(:broadcast)
  end

  it 'leaves younger needs_human rows untouched' do
    apply = aged(create(:apply, :needs_human), Apply::HUMAN_TIMEOUT - 1.hour)

    described_class.call

    expect(apply.reload).to be_needs_human
  end

  it 'fails needs_review older than 72 hours with review_expired' do
    old = aged(create(:apply, state: :needs_review, failure: { code: 'review', kind: 'review' }), Apply::REVIEW_TIMEOUT + 1.hour)
    young = aged(create(:apply, state: :needs_review), Apply::REVIEW_TIMEOUT - 1.hour)

    expect(described_class.call.model).to eq(human_timeout: 0, review_expired: 1, reminded: 1)

    expect(old.reload).to be_failed
    expect(old.failure).to include('code' => 'review_expired')
    expect(young.reload).to be_needs_review
  end

  it 'touches the user counter key' do
    apply = aged(create(:apply, :needs_human), Apply::HUMAN_TIMEOUT + 1.hour)

    expect { described_class.call }.to(change { apply.user.reload.applies_changed_at })
  end

  it 'processes at most batch_size rows per state per run' do
    create_list(:apply, 2, :needs_human).each { |apply| aged(apply, Apply::HUMAN_TIMEOUT + 1.hour) }

    expect(described_class.call(batch_size: 1).model[:human_timeout]).to eq(1)
    expect(described_class.call(batch_size: 1).model[:human_timeout]).to eq(1)
    expect(Apply.needs_human.count).to eq(0)
  end

  it 'does not overwrite a row the user already moved on' do
    apply = aged(create(:apply, :needs_human), Apply::HUMAN_TIMEOUT + 1.hour)
    allow(Apply::Operation::Engine::Lifecycle::Decide).to receive(:call).and_wrap_original do |original, **kwargs|
      Apply.where(id: apply.id).update_all(state: Apply.states.fetch(:cancelled))
      original.call(**kwargs)
    end

    expect(described_class.call.model[:human_timeout]).to eq(0)
    expect(apply.reload).to be_cancelled
  end

  it 'applies the claim rule: a claimed waiting apply expires into submit_unverified' do
    apply = aged(create(:apply, :needs_human, submit_claimed_at: 8.days.ago), Apply::HUMAN_TIMEOUT + 1.hour)

    described_class.call

    expect(apply.reload).to be_submit_unverified
    expect(apply.failure).to include('code' => 'human_timeout', 'after_claim' => true)
  end

  describe '48 h reminder' do
    it 'reminds a wait older than REMIND_AFTER once, without moving the expiry clock' do
      apply = aged(create(:apply, :needs_human), Apply::REMIND_AFTER + 1.hour)
      waiting_since = apply.reload.updated_at

      expect { expect(described_class.call.model[:reminded]).to eq(1) }
        .to(change { apply.user.reload.applies_changed_at })

      apply.reload
      expect(apply).to be_needs_human
      expect(apply).to be_reminded
      expect(apply.updated_at).to eq(waiting_since)
      expect(Apply::TurboHandler::StatusUpdate).to have_received(:broadcast)
      expect(described_class.call.model[:reminded]).to eq(0)
    end

    it 'leaves younger waits alone' do
      apply = aged(create(:apply, :needs_human), Apply::REMIND_AFTER - 1.hour)

      expect(described_class.call.model[:reminded]).to eq(0)
      expect(apply.reload.reminded_at).to be_nil
    end

    it 'reminds again after the apply re-entered the waiting state' do
      apply = aged(create(:apply, :needs_human), Apply::REMIND_AFTER + 1.hour)
      described_class.call
      # Resume -> run -> needs_human again: every transition bumps updated_at.
      aged(apply.reload, Apply::REMIND_AFTER + 1.minute)
      apply.update_columns(reminded_at: (Apply::REMIND_AFTER + 2.hours).ago)

      expect(apply.reload).not_to be_reminded
      expect(described_class.call.model[:reminded]).to eq(1)
      expect(apply.reload).to be_reminded
    end

    it 'does not remind a row the user acted on in between' do
      apply = aged(create(:apply, :needs_human), Apply::REMIND_AFTER + 1.hour)
      # The user resumes and the row comes back to needs_human between the SELECT and the reminder UPDATE.
      allow_any_instance_of(described_class).to receive(:remind_one).and_wrap_original do |original, *args|
        Apply.where(id: apply.id).update_all(updated_at: Time.current)
        original.call(*args)
      end

      expect(described_class.call.model[:reminded]).to eq(0)
      expect(apply.reload.reminded_at).to be_nil
    end
  end
end
