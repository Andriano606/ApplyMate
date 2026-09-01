# Elasticsearch only makes freshly indexed documents searchable after a refresh,
# and the default interval (1s) is too slow to rely on inside a scenario.
Given('the vacancy search index is refreshed') do
  Vacancy.__elasticsearch__.refresh_index!
end
