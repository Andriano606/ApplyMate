# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VacancyQuestion::Operation::New, type: :operation do
  let(:current_user) { create(:user) }
  let(:vacancy)      { create(:vacancy, source: create(:source)) }
  let(:params)       { { vacancy_id: vacancy.id } }

  it 'builds a blank question' do
    expect(result).to be_success
    expect(model.vacancy_question.question).to be_nil
  end

  context 'with a prefilled question' do
    let(:params) { { vacancy_id: vacancy.id, vacancy_question: { question: 'Why us?' } } }

    it 'prefills the question' do
      expect(model.vacancy_question.question).to eq('Why us?')
    end
  end
end
