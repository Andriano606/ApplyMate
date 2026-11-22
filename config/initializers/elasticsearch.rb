# frozen_string_literal: true

Elasticsearch::Model.client = Elasticsearch::Client.new(
  url: ENV.fetch('ELASTICSEARCH_URL', 'http://localhost:9200')
)

Rails.application.config.after_initialize do
  [ Vacancy ].each do |model|
    if model.__elasticsearch__.index_exists?
      # Adds fields introduced after the index was created (new fields only — changing
      # an existing field's type is rejected by Elasticsearch and needs a reindex).
      model.__elasticsearch__.client.indices.put_mapping(index: model.index_name, body: model.mappings.to_hash)
    else
      model.__elasticsearch__.create_index!
    end
  rescue => e
    # Not fatal (the app still serves pages without search), but loud: without the
    # mapping, filters on newly added fields (source_id) silently match nothing.
    Rails.logger.error "Elasticsearch index setup failed for #{model}: #{e.message}"
  end
end
