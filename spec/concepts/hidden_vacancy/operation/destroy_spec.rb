require "rails_helper"

RSpec.describe HiddenVacancy::Operation::Destroy, type: :operation do
  let(:current_user) { create(:user) }
  let(:vacancy) { create(:vacancy, source: create(:source)) }
  let(:params) { { vacancy_id: vacancy.hashid } }

  context "when the user hid the vacancy" do
    let!(:hidden) { current_user.hidden_vacancies.create!(vacancy:) }

    it "restores it" do
      expect(result).to be_success
      expect(model).to eq(hidden)
      expect(HiddenVacancy.exists?(hidden.id)).to be(false)
    end
  end

  context "when only another user hid the vacancy" do
    before { create(:user).hidden_vacancies.create!(vacancy:) }

    it "raises RecordNotFound and keeps the other user's row" do
      expect { result }.to raise_error(ActiveRecord::RecordNotFound)
      expect(HiddenVacancy.where(vacancy:).count).to eq(1)
    end
  end

  context "when nobody is signed in" do
    let(:current_user) { nil }

    it "is not authorized" do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
    end
  end
end
