# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Cancel, type: :operation do
  include_context 'with shared operation spec variables'

  let(:current_user) { create(:user) }
  let(:apply)        { create(:apply, user: current_user) }
  let(:params)       { { id: apply.hashid } }

  before { allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast) }

  it 'cancels a queued apply, rotating the run token, and broadcasts' do
    old_token = apply.run_token

    expect(result).to be_success
    expect(apply.reload).to be_cancelled
    expect(apply.run_token).to be_present
    expect(apply.run_token).not_to eq(old_token)
    expect(Apply::TurboHandler::StatusUpdate).to have_received(:broadcast).with(apply)
    expect(result.notice[:text]).to eq(I18n.t('apply.cancel.success'))
  end

  %i[failed needs_human].each do |trait|
    it "cancels a #{trait} apply" do
      apply = create(:apply, trait, user: current_user)

      described_class.call(params: { id: apply.hashid }, current_user:)

      expect(apply.reload).to be_cancelled
    end
  end

  it 'refuses a running apply' do
    apply = create(:apply, :running, user: current_user)
    result = described_class.call(params: { id: apply.hashid }, current_user:)

    expect(result.errors[:base]).to eq([ I18n.t('apply.cancel.not_allowed') ])
    expect(apply.reload).to be_running
  end

  it 'refuses a submit_unverified apply' do
    apply = create(:apply, :claimed, user: current_user)
    result = described_class.call(params: { id: apply.hashid }, current_user:)

    expect(result).to be_failure
    expect(apply.reload).to be_submit_unverified
  end

  it 'makes a job that starts afterwards leave the cancelled apply alone' do
    result

    expect { Apply::Job::Apply.perform_now(apply.id) }.not_to raise_error
    expect(apply.reload).to be_cancelled
  end

  it "does not find another user's apply" do
    other = create(:apply)

    expect { described_class.call(params: { id: other.hashid }, current_user:) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end
end
