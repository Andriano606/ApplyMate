# frozen_string_literal: true

Elasticsearch::Model.client = Elasticsearch::Client.new(
  url: ENV.fetch('ELASTICSEARCH_URL', 'http://localhost:9200')
)

Rails.application.config.after_initialize do
  ApplicationRecord.descendants.select { |m| m.include?(Elasticsearch::Model) }.each do |model|
    model.__elasticsearch__.create_index! unless model.__elasticsearch__.index_exists?
  rescue => e
    Rails.logger.warn "Elasticsearch index setup failed for #{model}: #{e.message}"
  end
end
