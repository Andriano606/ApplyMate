# frozen_string_literal: true

class Vacancy < ApplicationRecord
  include Elasticsearch::Model
  include Elasticsearch::Model::Callbacks

  belongs_to :source

  index_name "vacancies_#{Rails.env}"

  settings index: { number_of_shards: 1, number_of_replicas: 0 } do
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
    end
  end

  def as_indexed_json(_options = {})
    { title:, company_name:, description: }
  end
end
