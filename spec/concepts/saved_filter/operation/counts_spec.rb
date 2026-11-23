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

  def preset(tag, exclude_tags: [])
    create(:saved_filter, user:, include_tags: [ tag ], include_ops: [], exclude_tags:)
  end

  def index_vacancy(title)
    create(:vacancy, source:, title:, company_name: "Corp", description: "role").tap do |v|
      v.__elasticsearch__.index_document
    end
  end

  it "counts the vacancies each preset matches, in one go" do
    embedded = preset("embedded")
    python   = preset("python", exclude_tags: %w[junior])
    empty    = preset("cobol")
    index_vacancy("Embedded Developer")
    index_vacancy("Embedded Engineer")
    index_vacancy("Python Developer")
    index_vacancy("Junior Python Developer")
    Vacancy.__elasticsearch__.refresh_index!
    Rails.cache.clear

    counts = described_class.call(saved_filters: [ embedded, python, empty ]).model

    expect(counts).to eq(embedded.id => 2, python.id => 1, empty.id => 0)
  end

  it "returns an empty hash when Elasticsearch fails" do
    allow(Elasticsearch::Model.client).to receive(:msearch).and_raise(StandardError, "down")
    Rails.cache.clear

    expect(described_class.call(saved_filters: [ preset("embedded") ]).model).to eq({})
  end
end
