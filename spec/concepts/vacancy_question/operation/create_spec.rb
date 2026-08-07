# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VacancyQuestion::Operation::Create, type: :operation do
  let(:current_user)     { create(:user) }
  let(:source)           { create(:source) }
  let(:vacancy)          { create(:vacancy, source:) }
  let(:user_profile)     { create(:user_profile, user: current_user) }
  let(:ai_integration)   { create(:ai_integration, user: current_user) }
  let(:fill_form_prompt) { create(:prompt, user: current_user) }
  let(:question)         { 'Чому ви хочете працювати саме у нашій компанії?' }

  let(:params) do
    {
      vacancy_id: vacancy.id,
      vacancy_question: {
        question:,
        user_profile_id:     user_profile.id,
        ai_integration_id:   ai_integration.id,
        fill_form_prompt_id: fill_form_prompt.id
      }
    }
  end

  before do
    allow(VacancyQuestion::Job::Create).to receive(:perform_later)
  end

  it 'creates the question and enqueues the generation job' do
    expect { result }.to change(VacancyQuestion, :count).by(1)
    expect(result).to be_success
    expect(model.vacancy_question.question).to eq(question)
    expect(model.vacancy_question.answer).to be_nil
    expect(VacancyQuestion::Job::Create).to have_received(:perform_later).with(model.vacancy_question.id)
  end

  context 'with a blank question' do
    let(:question) { '' }

    it 'fails without creating a record or enqueueing a job' do
      expect { result }.not_to change(VacancyQuestion, :count)
      expect(result).to be_failure
      expect(VacancyQuestion::Job::Create).not_to have_received(:perform_later)
    end
  end

  context 'when not signed in' do
    let(:current_user) { nil }
    let(:user)         { create(:user) }
    let(:user_profile) { create(:user_profile, user:) }
    let(:ai_integration)   { create(:ai_integration, user:) }
    let(:fill_form_prompt) { create(:prompt, user:) }

    it 'raises authorization error' do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
    end
  end
end
