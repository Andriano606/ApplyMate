# frozen_string_literal: true

class Vacancy < ApplicationRecord
  include Elasticsearch::Model
  include Elasticsearch::Model::Callbacks

  belongs_to :source

  # Deepest hit (from + size) a search may page to; Vacancy::Operation::Search clamps the page to it.
  MAX_RESULT_WINDOW = 50_000

  index_name [ 'vacancies', Rails.env, ENV['ES_INDEX_NAMESPACE'].presence ].compact.join('_')

  settings index: { number_of_shards: 1, number_of_replicas: 0, max_result_window: MAX_RESULT_WINDOW } do
    mappings dynamic: false do
      indexes :title,        type: :text, analyzer: :standard do
        indexes :keyword, type: :keyword
      end
      indexes :company_name, type: :text, analyzer: :standard do
        indexes :keyword, type: :keyword
      end
      indexes :description,  type: :text, analyzer: :standard do
        indexes :keyword, type: :keyword
      end
      indexes :vacancy_id, type: :integer
      # Added after the index existed: config/initializers/elasticsearch.rb puts it onto
      # existing indices, and each sync run re-imports every listed vacancy, which fills it.
      indexes :source_id, type: :integer
    end
  end

  # One predicate for both description columns: rows scraped before markup was stored
  # only have the text, new rows have both. Views guard on this so the markup card and
  # the collapsed apply card can never disagree about whether there is a description.
  def description_present?
    description_html.present? || description.present?
  end

  def as_indexed_json(_options = {})
    { title:, company_name:, description:, vacancy_id: id, source_id: }
  end
end
