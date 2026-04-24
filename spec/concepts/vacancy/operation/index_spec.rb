# frozen_string_literal: true

require "rails_helper"

RSpec.describe ::Vacancy::Operation::Index, type: :operation do
  include_context "with elasticsearch index"

  after do
    Elasticsearch::Model.client.delete_by_query(
      index: Vacancy.index_name,
      body:  { query: { match_all: {} } },
      refresh: true
    )
  end

  let(:source) { create(:source) }

  let(:vacancy_rails) do
    create(:vacancy, source:, title: "Ruby on Rails Developer",
                     company_name: "Acme Corp", description: "Rails expert needed")
  end
  let(:vacancy_python) do
    create(:vacancy, source:, title: "Python Engineer",
                     company_name: "Globex", description: "Python developer role")
  end
  let(:vacancy_frontend) do
    create(:vacancy, source:, title: "Rails Frontend Developer",
                     company_name: "Initech", description: "Frontend Rails position")
  end

  # after_commit callbacks do not fire inside RSpec transactions,
  # so we index manually and refresh before each test.
  before do
    vacancy_rails; vacancy_python; vacancy_frontend
    [ vacancy_rails, vacancy_python, vacancy_frontend ].each { |v| v.__elasticsearch__.index_document }
    Vacancy.__elasticsearch__.refresh_index!
  end

  context "when no query or exclude given" do
    it "returns all vacancies as a WillPaginate collection with correct total" do
      expect(result).to be_success
      expect(model).to be_a(WillPaginate::Collection)
      expect(model.map(&:id)).to contain_exactly(vacancy_rails.id, vacancy_python.id, vacancy_frontend.id)
      expect(model.total_entries).to eq(3)
    end
  end

  context "when query matches by title" do
    let(:params) { { query: "rails" } }

    it "returns only vacancies whose content contains the query term" do
      expect(result).to be_success
      expect(model.map(&:id)).to contain_exactly(vacancy_rails.id, vacancy_frontend.id)
    end
  end

  context "when exclude filter is given" do
    let(:params) { { exclude: "python" } }

    it "excludes vacancies matching the excluded term" do
      expect(result).to be_success
      expect(model.map(&:id)).to contain_exactly(vacancy_rails.id, vacancy_frontend.id)
    end
  end

  context "when both query and exclude are given" do
    let(:params) { { query: "rails", exclude: "frontend" } }

    it "returns vacancies matching query but not exclude" do
      expect(result).to be_success
      expect(model.map(&:id)).to contain_exactly(vacancy_rails.id)
    end
  end

  context "when paginating" do
    let(:params) { { page: "1" } }

    it "returns correct pagination metadata" do
      expect(result).to be_success
      expect(model.current_page).to eq(1)
      expect(model.per_page).to eq(WillPaginate.per_page)
      expect(model.total_entries).to eq(3)
    end
  end

  context "when exclude contains multiple space-separated words each matching different vacancies" do
    let(:vacancy_next) { create(:vacancy, source:, title: "Rails Next",    company_name: "Acme", description: "Next position") }
    let(:vacancy_nexs) { create(:vacancy, source:, title: "Rails Nexs",    company_name: "Beta", description: "Nexs position") }
    let(:params) { { query: "rails", exclude: "Nexs Next" } }

    before do
      vacancy_next; vacancy_nexs
      [ vacancy_next, vacancy_nexs ].each { |v| v.__elasticsearch__.index_document }
      Vacancy.__elasticsearch__.refresh_index!
    end

    it "excludes vacancies matching any word from the exclude string" do
      expect(result).to be_success
      expect(model.map(&:id)).not_to include(vacancy_next.id, vacancy_nexs.id)
    end
  end

  context "when exclude word partially matches a compound term like Next.js" do
    let(:vacancy_nextjs) { create(:vacancy, source:, title: "Rails Next.js Developer", company_name: "Acme", description: "Next.js position") }
    let(:vacancy_nexs)   { create(:vacancy, source:, title: "Rails Nexs",              company_name: "Beta", description: "Nexs position") }
    let(:params) { { query: "rails", exclude: "Nexs Next" } }

    before do
      vacancy_nextjs; vacancy_nexs
      [ vacancy_nextjs, vacancy_nexs ].each { |v| v.__elasticsearch__.index_document }
      Vacancy.__elasticsearch__.refresh_index!
    end

    it "excludes vacancies whose title contains a token matching any exclude word" do
      expect(result).to be_success
      expect(model.map(&:id)).not_to include(vacancy_nextjs.id, vacancy_nexs.id)
    end
  end

  context "when query has no matches" do
    let(:params) { { query: "cobol" } }

    it "returns an empty collection" do
      expect(result).to be_success
      expect(model).to be_empty
      expect(model.total_entries).to eq(0)
    end
  end
end
