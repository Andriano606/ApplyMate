# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vacancy::Operation::Search, type: :operation do
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

  before do
    vacancy_rails; vacancy_python; vacancy_frontend
    [ vacancy_rails, vacancy_python, vacancy_frontend ].each { |v| v.__elasticsearch__.index_document }
    Vacancy.__elasticsearch__.refresh_index!
  end

  context "when no include_tags or exclude_tags given" do
    it "returns all vacancies as a WillPaginate collection with correct total" do
      expect(result).to be_success
      expect(model).to be_a(WillPaginate::Collection)
      expect(model.map(&:id)).to contain_exactly(vacancy_rails.id, vacancy_python.id, vacancy_frontend.id)
      expect(model.total_entries).to eq(3)
    end
  end

  context "when include_tags matches by title" do
    let(:params) { { include_tags: [ 'rails' ] } }

    it "returns only vacancies whose content contains the tag" do
      expect(result).to be_success
      expect(model.map(&:id)).to contain_exactly(vacancy_rails.id, vacancy_frontend.id)
    end
  end

  context "when exclude_tags filter is given" do
    let(:params) { { exclude_tags: [ 'python' ] } }

    it "excludes vacancies matching the excluded tag" do
      expect(result).to be_success
      expect(model.map(&:id)).to contain_exactly(vacancy_rails.id, vacancy_frontend.id)
    end
  end

  context "when both include_tags and exclude_tags are given" do
    let(:params) { { include_tags: [ 'rails' ], exclude_tags: [ 'frontend' ] } }

    it "returns vacancies matching include but not exclude" do
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

  context "when multiple exclude_tags each match different vacancies" do
    let(:vacancy_next) { create(:vacancy, source:, title: "Rails Next",    company_name: "Acme", description: "Next position") }
    let(:vacancy_nexs) { create(:vacancy, source:, title: "Rails Nexs",    company_name: "Beta", description: "Nexs position") }
    let(:params) { { include_tags: [ 'rails' ], exclude_tags: [ 'Nexs', 'Next' ] } }

    before do
      vacancy_next; vacancy_nexs
      [ vacancy_next, vacancy_nexs ].each { |v| v.__elasticsearch__.index_document }
      Vacancy.__elasticsearch__.refresh_index!
    end

    it "excludes vacancies matching any tag from the exclude list" do
      expect(result).to be_success
      expect(model.map(&:id)).not_to include(vacancy_next.id, vacancy_nexs.id)
    end
  end

  context "when an exclude tag partially matches a compound term like Next.js" do
    let(:vacancy_nextjs) { create(:vacancy, source:, title: "Rails Next.js Developer", company_name: "Acme", description: "Next.js position") }
    let(:vacancy_nexs)   { create(:vacancy, source:, title: "Rails Nexs",              company_name: "Beta", description: "Nexs position") }
    let(:params) { { include_tags: [ 'rails' ], exclude_tags: [ 'Nexs', 'Next' ] } }

    before do
      vacancy_nextjs; vacancy_nexs
      [ vacancy_nextjs, vacancy_nexs ].each { |v| v.__elasticsearch__.index_document }
      Vacancy.__elasticsearch__.refresh_index!
    end

    it "excludes vacancies whose fields contain a token matching any exclude tag" do
      expect(result).to be_success
      expect(model.map(&:id)).not_to include(vacancy_nextjs.id, vacancy_nexs.id)
    end
  end

  context "when include_tags has no matches" do
    let(:params) { { include_tags: [ 'cobol' ] } }

    it "returns an empty collection" do
      expect(result).to be_success
      expect(model).to be_empty
      expect(model.total_entries).to eq(0)
    end
  end

  context "when two tags are connected with OR" do
    let(:params) { { include_tags: [ 'Ruby', 'Python' ], include_ops: [ 'or' ] } }

    it "returns vacancies matching either tag" do
      expect(result).to be_success
      expect(model.map(&:id)).to contain_exactly(vacancy_rails.id, vacancy_python.id)
    end
  end

  context "when two tags are connected with AND" do
    let(:params) { { include_tags: [ 'Ruby', 'Developer' ], include_ops: [ 'and' ] } }

    it "returns only vacancies containing both tags" do
      expect(result).to be_success
      expect(model.map(&:id)).to contain_exactly(vacancy_rails.id)
    end
  end

  context "when a single include tag is a multi-word phrase" do
    let(:params) { { include_tags: [ 'Ruby on Rails' ] } }

    it "returns only vacancies containing the exact phrase" do
      expect(result).to be_success
      expect(model.map(&:id)).to contain_exactly(vacancy_rails.id)
    end
  end

  shared_context "with embedded vacancies" do
    let(:vacancy_emb_remote) do
      create(:vacancy, source:, title: "Embedded Developer",
                       company_name: "IoT Corp", description: "STM32 firmware, remote work")
    end
    let(:vacancy_emb_office) do
      create(:vacancy, source:, title: "Embedded Engineer",
                       company_name: "HW Corp", description: "STM32 firmware, office in Kyiv")
    end
    let(:vacancy_emb_viddaleno) do
      create(:vacancy, source:, title: "Embedded C Developer",
                       company_name: "FW Corp", description: "STM32, віддалено, повна зайнятість")
    end

    before do
      [ vacancy_emb_remote, vacancy_emb_office, vacancy_emb_viddaleno ].each { |v| v.__elasticsearch__.index_document }
      Vacancy.__elasticsearch__.refresh_index!
    end
  end

  context "when a tag is a nested boolean expression: embedded і stm32 і (remote або віддалено)" do
    include_context "with embedded vacancies"

    let(:params) { { include_tags: [ '(embedded і stm32 і (remote або віддалено))' ] } }

    it "returns vacancies matching embedded AND stm32 AND (remote OR віддалено)" do
      expect(result).to be_success
      expect(model.map(&:id)).to contain_exactly(vacancy_emb_remote.id, vacancy_emb_viddaleno.id)
    end
  end

  context "when ops contain an explicit OR group: embedded AND stm32 AND (remote g_or віддалено)" do
    include_context "with embedded vacancies"

    let(:params) do
      { include_tags: [ 'embedded', 'stm32', 'remote', 'віддалено' ],
        include_ops:  [ 'and', 'and', 'g_or' ] }
    end

    it "applies the OR group before the ANDs" do
      expect(result).to be_success
      expect(model.map(&:id)).to contain_exactly(vacancy_emb_remote.id, vacancy_emb_viddaleno.id)
    end
  end

  context "when an explicit OR group starts the chain: (remote g_or віддалено) AND stm32" do
    include_context "with embedded vacancies"

    let(:params) do
      { include_tags: [ 'remote', 'віддалено', 'stm32' ],
        include_ops:  [ 'g_or', 'and' ] }
    end

    it "requires stm32 plus either alternative from the group" do
      expect(result).to be_success
      expect(model.map(&:id)).to contain_exactly(vacancy_emb_remote.id, vacancy_emb_viddaleno.id)
    end
  end

  context "when an expression tag is combined with existing vacancies" do
    let(:params) { { include_tags: [ 'rails і (python або frontend)' ] } }

    it "applies the nested logic within a single tag" do
      expect(result).to be_success
      expect(model.map(&:id)).to contain_exactly(vacancy_frontend.id)
    end
  end

  context "when an exclude tag is a boolean expression" do
    let(:params) { { exclude_tags: [ '(python або frontend)' ] } }

    it "excludes vacancies matching either alternative" do
      expect(result).to be_success
      expect(model.map(&:id)).to contain_exactly(vacancy_rails.id)
    end
  end

  context "when 3 tags with mixed operators: (rails AND ruby) OR react" do
    let(:vacancy_react) do
      create(:vacancy, source:, title: "React Developer", company_name: "Startup", description: "React.js role")
    end
    let(:params) { { include_tags: [ 'rails', 'ruby', 'react' ], include_ops: [ 'and', 'or' ] } }

    before do
      vacancy_react.__elasticsearch__.index_document
      Vacancy.__elasticsearch__.refresh_index!
    end

    it "returns vacancies matching (rails AND ruby) or react" do
      expect(result).to be_success
      expect(model.map(&:id)).to contain_exactly(vacancy_rails.id, vacancy_react.id)
    end
  end
end
