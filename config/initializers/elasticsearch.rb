# frozen_string_literal: true

Elasticsearch::Model.client = Elasticsearch::Client.new(
  url: ENV.fetch('ELASTICSEARCH_URL', 'http://localhost:9200')
)

# This runs in every web/worker boot, and kamal-proxy gives a new web container
# only 30s to answer /up — so it must never wait on Elasticsearch for long.
# Mapping changes are cluster-state updates: on a healthy node they take
# milliseconds, but a stuck master queues them until its own 30s timeout, which
# is exactly how a deploy once failed. Hence: read first, write only when a field
# is missing, and cap the write at MAPPING_UPDATE_TIMEOUT.
MAPPING_UPDATE_TIMEOUT = '5s'

Rails.application.config.after_initialize do
  [ Vacancy ].each do |model|
    es = model.__elasticsearch__

    if es.index_exists?
      # Adds fields introduced after the index was created (new fields only — changing
      # an existing field's type is rejected by Elasticsearch and needs a reindex).
      present = es.client.indices.get_mapping(index: model.index_name).values.first
                  .dig('mappings', 'properties')&.keys || []
      missing = model.mappings.to_hash[:properties].keys.map(&:to_s) - present

      if missing.any?
        es.client.indices.put_mapping(index: model.index_name, body: model.mappings.to_hash,
                                      master_timeout: MAPPING_UPDATE_TIMEOUT, timeout: MAPPING_UPDATE_TIMEOUT)
        Rails.logger.info "Elasticsearch mapping for #{model} gained: #{missing.join(', ')}"
      end
    else
      es.create_index!
    end
  rescue => e
    # Not fatal (the app still serves pages without search), but loud: without the
    # mapping, filters on newly added fields (source_id) silently match nothing.
    Rails.logger.error "Elasticsearch index setup failed for #{model}: #{e.message}"
  end
end
