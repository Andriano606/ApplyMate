# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::MarkOutcome, type: :operation do
  include_context 'with shared operation spec variables'

  let(:current_user) { create(:user) }
  let(:apply)        { create(:apply, :claimed, user: current_user) }
  let(:outcome)      { 'sent' }
  let(:confirm)      { nil }
  let(:params)       { { id: apply.hashid, outcome:, confirm: }.compact }

  before { allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast) }

  context 'with sent' do
    it 'completes the apply as submitted by the engine' do
      expect(result).to be_success
      expect(apply.reload).to be_completed
      expect(apply.submitted_at).to be_present
      expect(apply.submitted_via).to eq('engine')
      expect(Apply::TurboHandler::StatusUpdate).to have_received(:broadcast).with(apply)
      expect(result.notice[:text]).to eq(I18n.t('apply.mark_outcome.success.sent'))
    end

    it 'is refused from needs_human' do
      apply.update_columns(state: Apply.states[:needs_human])

      expect(result.errors[:base]).to eq([ I18n.t('apply.mark_outcome.not_allowed') ])
    end
  end

  context 'with not_sent' do
    let(:outcome) { 'not_sent' }

    it 'requires confirmation' do
      expect(result.errors[:base]).to eq([ I18n.t('apply.mark_outcome.confirm_required') ])
      expect(apply.reload).to be_submit_unverified
    end

    context 'when confirmed' do
      let(:confirm) { '1' }

      it 'fails the apply, releases the claim and keeps the failure' do
        expect(result).to be_success
        expect(apply.reload).to be_failed
        expect(apply.submit_claimed_at).to be_nil
        expect(apply.failure).to include('code' => 'outcome_unknown', 'resolved' => 'not_sent')
      end

      it 'frees the open-claim index so the vacancy can be applied to again' do
        result

        expect { create(:apply, :claimed, user: current_user, vacancy: apply.vacancy, state: :failed) }
          .not_to raise_error
      end
    end
  end

  context 'with manual' do
    let(:outcome) { 'manual' }

    it 'completes a needs_human apply as submitted manually' do
      apply = create(:apply, :needs_human, user: current_user)
      described_class.call(params: { id: apply.hashid, outcome: }, current_user:)

      expect(apply.reload).to be_completed
      expect(apply.submitted_via).to eq('manual')
      expect(apply.submitted_at).to be_present
      expect(apply.submit_claimed_at).to be_nil
    end

    it 'completes a submit_unverified apply and keeps the claim' do
      expect(result).to be_success
      expect(apply.reload).to be_completed
      expect(apply.submitted_via).to eq('manual')
      expect(apply.submit_claimed_at).to be_present
    end

    it 'is refused from a running apply' do
      apply = create(:apply, :running, user: current_user)
      result = described_class.call(params: { id: apply.hashid, outcome: }, current_user:)

      expect(result.errors[:base]).to eq([ I18n.t('apply.mark_outcome.not_allowed') ])
      expect(apply.reload).to be_running
    end
  end

  it 'refuses an unknown outcome' do
    result = described_class.call(params: { id: apply.hashid, outcome: 'bogus' }, current_user:)

    expect(result.errors[:base]).to eq([ I18n.t('apply.mark_outcome.not_allowed') ])
  end

  it "does not find another user's apply" do
    other = create(:apply, :claimed)

    expect { described_class.call(params: { id: other.hashid, outcome: 'sent' }, current_user:) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end
end
