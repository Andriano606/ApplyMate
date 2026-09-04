# frozen_string_literal: true

class Vacancy < ApplicationRecord
  include Elasticsearch::Model
  include Elasticsearch::Model::Callbacks

  belongs_to :source

  has_many :applies,           dependent: :destroy
  has_many :vacancy_cvs,       dependent: :destroy
  has_many :vacancy_questions, dependent: :destroy
  has_many :hidden_vacancies,  dependent: :delete_all

  index_name [ 'vacancies', Rails.env, ENV['ES_INDEX_NAMESPACE'].presence ].compact.join('_')

  settings index: { number_of_shards: 1, number_of_replicas: 0, max_result_window: 50_000 } do
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
    end
  end

  # One predicate for both description columns: rows scraped before markup was stored
  # only have the text, new rows have both. Views guard on this so the markup card and
  # the collapsed apply card can never disagree about whether there is a description.
  def description_present?
    description_html.present? || description.present?
  end

  def as_indexed_json(_options = {})
    { title:, company_name:, description:, vacancy_id: id }
  end
end
