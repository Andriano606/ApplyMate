# frozen_string_literal: true

BeforeAll do
  Vacancy.__elasticsearch__.create_index! force: true
end

AfterAll do
  Vacancy.__elasticsearch__.delete_index!
end

# Refresh first: delete_by_query deletes from a search snapshot, so a document a
# previous scenario updated without a refresh still has its old version there
# and the delete fails with a 409 version conflict.
Before do
  Vacancy.__elasticsearch__.refresh_index!
  Elasticsearch::Model.client.delete_by_query(
    index: Vacancy.index_name,
    body:  { query: { match_all: {} } },
    refresh: true
  )
end
