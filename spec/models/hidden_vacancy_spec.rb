require "rails_helper"

RSpec.describe HiddenVacancy do
  let(:user)   { create(:user) }
  let(:source) { create(:source) }

  describe ".vacancy_ids_for" do
    let!(:vacancies) { Array.new(3) { create(:vacancy, source:) } }

    before { user.hidden_vacancies.create!(vacancy: vacancies.first) }

    it "returns only the given vacancies the user hid" do
      expect(described_class.vacancy_ids_for(user:, vacancies:)).to eq([ vacancies.first.id ])
    end

    it "ignores vacancies outside the given page" do
      expect(described_class.vacancy_ids_for(user:, vacancies: vacancies.last(2))).to be_empty
    end

    it "does not leak other users' rows" do
      expect(described_class.vacancy_ids_for(user: create(:user), vacancies:)).to be_empty
    end

    it "returns nothing for guests" do
      expect(described_class.vacancy_ids_for(user: nil, vacancies:)).to eq([])
    end
  end

  it "is unique per user and vacancy" do
    vacancy = create(:vacancy, source:)
    user.hidden_vacancies.create!(vacancy:)

    expect { user.hidden_vacancies.create!(vacancy:) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
