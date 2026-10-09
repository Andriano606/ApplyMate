# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::VacancyIndex, type: :operation do
  let(:current_user) { create(:user) }
  let(:vacancy)      { create(:vacancy, source: create(:source)) }
  let(:params)       { { vacancy_id: vacancy.hashid } }

  let!(:older_apply) { create(:apply, :completed, user: current_user, vacancy:, created_at: 2.days.ago) }
  let!(:newer_apply) { create(:apply, user: current_user, vacancy:, created_at: 1.day.ago) }

  before do
    create(:apply, user: create(:user), vacancy:)
    create(:apply, user: current_user)
  end

  it "returns only the current user's applies for the vacancy, newest first" do
    expect(result).to be_success
    expect(model.vacancy).to eq(vacancy)
    expect(model.applies).to eq([ newer_apply, older_apply ])
  end
end
