# frozen_string_literal: true

BeforeAll do
  Vacancy.__elasticsearch__.create_index! force: true
end

AfterAll do
  Vacancy.__elasticsearch__.delete_index!
end

Before do
  Elasticsearch::Model.client.delete_by_query(
    index: Vacancy.index_name,
    body:  { query: { match_all: {} } },
    refresh: true
  )
end
