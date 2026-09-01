# frozen_string_literal: true

require "rails_helper"

RSpec.describe SavedFilter::Operation::Counts, type: :operation do
  include_context "with elasticsearch index"

  after do
    Elasticsearch::Model.client.delete_by_query(
      index: Vacancy.index_name,
      body:  { query: { match_all: {} } },
      refresh: true
    )
  end

  let(:user)   { create(:user) }
  let(:source) { create(:source) }
  let(:saved_filter) do
    create(:saved_filter, user:, include_tags: %w[embedded], include_ops: [], exclude_tags: [])
  end

  def index_vacancy(title)
    create(:vacancy, source:, title:, company_name: "Corp", description: "role").tap do |v|
      v.__elasticsearch__.index_document
    end
  end

  def stats_for(filter)
    Rails.cache.clear
    described_class.call(saved_filters: [ filter.reload ]).model[filter.id]
  end

  it "counts matching vacancies and hides deltas before the first view" do
    index_vacancy("Embedded Developer")
    index_vacancy("Python Developer")
    Vacancy.__elasticsearch__.refresh_index!

    stat = stats_for(saved_filter)
    expect(stat.count).to eq(1)
    expect(stat.appeared).to be_nil
    expect(stat.disappeared).to be_nil
  end

  it "reports appeared and disappeared relative to the last view snapshot" do
    seen    = index_vacancy("Embedded Developer")
    gone    = index_vacancy("Embedded Engineer")
    Vacancy.__elasticsearch__.refresh_index!

    saved_filter.record_view!(count: 2, max_vacancy_id: gone.id)

    gone.__elasticsearch__.delete_document
    index_vacancy("Embedded C Developer")
    index_vacancy("Embedded Rust Developer")
    Vacancy.__elasticsearch__.refresh_index!

    stat = stats_for(saved_filter)
    expect(stat.count).to eq(3)       # seen + 2 new
    expect(stat.appeared).to eq(2)
    expect(stat.disappeared).to eq(1) # 2 (seen) + 2 (appeared) - 3 (current)
    expect(seen.id).to be < gone.id
  end

  it "returns an empty hash when Elasticsearch fails" do
    allow(Elasticsearch::Model.client).to receive(:msearch).and_raise(StandardError, "down")
    Rails.cache.clear

    expect(described_class.call(saved_filters: [ saved_filter ]).model).to eq({})
  end
end
