# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VacancyQuestion::Operation::Index, type: :operation do
  let(:current_user) { create(:user) }
  let(:source)       { create(:source) }
  let(:vacancy)      { create(:vacancy, source:) }
  let(:params)       { { vacancy_id: vacancy.id } }

  let!(:own_question) do
    create(:vacancy_question, vacancy:, user_profile: create(:user_profile, user: current_user))
  end
  let!(:other_question) do
    create(:vacancy_question, vacancy:, user_profile: create(:user_profile, user: create(:user)))
  end

  it 'returns only questions of the current user for the vacancy' do
    expect(result).to be_success
    expect(model.vacancy_questions).to contain_exactly(own_question)
  end
end
