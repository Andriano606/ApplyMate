require "rails_helper"

RSpec.describe HiddenVacancy::Operation::Create, type: :operation do
  let(:current_user) { create(:user) }
  let(:vacancy) { create(:vacancy, source: create(:source)) }
  let(:params) { { vacancy_id: vacancy.hashid } }

  it "hides the vacancy for the user" do
    expect(result).to be_success
    expect(model).to be_persisted
    expect(current_user.hidden_vacancies.pluck(:vacancy_id)).to eq([ vacancy.id ])
  end

  context "when the vacancy is already hidden" do
    let!(:existing) { current_user.hidden_vacancies.create!(vacancy:) }

    it "reuses the existing row" do
      expect(result).to be_success
      expect(model).to eq(existing)
      expect(HiddenVacancy.where(user: current_user, vacancy:).count).to eq(1)
    end
  end

  context "when nobody is signed in" do
    let(:current_user) { nil }

    it "is not authorized" do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  context "when the vacancy does not exist" do
    let(:params) { { vacancy_id: 'missing' } }

    it "raises RecordNotFound" do
      expect { result }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
