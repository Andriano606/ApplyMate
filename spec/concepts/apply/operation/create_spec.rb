# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Create, type: :operation do
  let(:current_user)   { create(:user) }
  let(:source)         { create(:source) }
  let(:vacancy)        { create(:vacancy, source:) }
  let(:user_profile)   { create(:user_profile, user: current_user) }
  let(:ai_integration) { create(:ai_integration, user: current_user) }
  let(:source_profile) { create(:source_profile, user: current_user, source:) }
  let(:fill_prompt)    { create(:prompt, user: current_user) }
  let(:cv_prompt)      { create(:prompt, :generate_cv, user: current_user) }
  let(:confirm)        { nil }
  let(:params) do
    {
      apply: {
        vacancy_id: vacancy.id, user_profile_id: user_profile.id, ai_integration_id: ai_integration.id,
        source_profile_id: source_profile.id, fill_form_prompt_id: fill_prompt.id,
        generate_cv_prompt_id: cv_prompt.id, confirm_reapply: confirm
      }.compact
    }
  end

  before { allow(Apply::TurboHandler::StatusUpdate).to receive(:refresh) }

  def base_errors
    result.errors[:base]
  end

  it 'creates a queued apply, enqueues the job and stores its id' do
    expect { result }.to have_enqueued_job(Apply::Job::Apply)

    expect(result).to be_success
    expect(model).to be_persisted.and be_queued
    expect(model.reload.job_id).to be_present
    expect(result.notice[:text]).to eq(I18n.t('apply.create.success'))
  end

  it 'bumps the attention counter key of the user' do
    expect { result }.to(change { current_user.reload.applies_changed_at })
  end

  it 'rejects a second active apply for the same vacancy through the unique index' do
    create(:apply, user: current_user, vacancy:)

    expect { result }.not_to have_enqueued_job(Apply::Job::Apply)

    expect(result).to be_failure
    expect(base_errors).to eq([ I18n.t('apply.create.already_active') ])
    expect(current_user.applies.count).to eq(1)
  end

  context 'with a previous apply that was claimed' do
    before { create(:apply, :claimed, user: current_user, vacancy:) }

    it 'requires confirm_reapply' do
      expect(result).to be_failure
      expect(base_errors).to eq([ I18n.t('apply.create.reapply_confirmation_required') ])
    end
  end

  context 'with a previous completed apply' do
    before { create(:apply, :completed, user: current_user, vacancy:) }

    it 'requires confirm_reapply' do
      expect(base_errors).to eq([ I18n.t('apply.create.reapply_confirmation_required') ])
    end

    context 'when confirmed' do
      let(:confirm) { '1' }

      it 'creates the apply' do
        expect(result).to be_success
        expect(current_user.applies.count).to eq(2)
      end
    end
  end

  context 'when the daily limit is reached' do
    before do
      current_user.update!(daily_apply_limit: 2)
      2.times { create(:apply, :failed, user: current_user) }
    end

    it 'refuses the new apply' do
      expect(result).to be_failure
      expect(base_errors).to eq([ I18n.t('apply.create.daily_limit_reached', limit: 2) ])
    end

    it "ignores yesterday's applies" do
      current_user.applies.update_all(created_at: 1.day.ago)

      expect(result).to be_success
    end
  end
end
