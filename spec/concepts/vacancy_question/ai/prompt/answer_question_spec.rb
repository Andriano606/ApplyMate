# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VacancyQuestion::Ai::Prompt::AnswerQuestion do
  let(:user)         { create(:user) }
  let(:source)       { create(:source) }
  let(:vacancy)      { create(:vacancy, source:, description: 'Vacancy description', details: 'Vacancy details') }
  let(:user_profile) { create(:user_profile, user:, cv: 'My experience') }
  let(:vacancy_question) do
    create(:vacancy_question, vacancy:, user_profile:, fill_form_prompt:, question: 'Який ваш досвід з Ruby?')
  end

  context 'with a user fill_form prompt' do
    let(:fill_form_prompt) { create(:prompt, user:) }

    it 'substitutes all placeholders into the user template' do
      prompt = described_class.call(vacancy_question)

      expect(prompt).to include('Custom template.')
      expect(prompt).to include("Vacancy description\n\nVacancy details")
      expect(prompt).to include('My experience')
      expect(prompt).to include('Який ваш досвід з Ruby?')
      expect(prompt).not_to include('PLACEHOLDER_')
    end
  end

  context 'without a fill_form prompt' do
    let(:fill_form_prompt) { nil }
    let(:vacancy_question) do
      build(:vacancy_question, vacancy:, user_profile:, fill_form_prompt: nil, question: 'Який ваш досвід з Ruby?')
    end

    it 'falls back to the default template' do
      prompt = described_class.call(vacancy_question)

      expect(prompt).to include('Роль: Ти — професійний кар\'єрний консультант')
      expect(prompt).to include('Який ваш досвід з Ruby?')
      expect(prompt).not_to include('PLACEHOLDER_')
    end
  end
end
