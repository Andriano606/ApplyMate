# frozen_string_literal: true

# How many vacancies match each preset right now (result model:
# { saved_filter.id => count }), for the badges in the pills row.
#
# One ES msearch covers all presets. Counts move only when a sync run changes
# the vacancies or a preset is edited, so they are cached; the key includes the
# presets' cache versions (updated_at), so an edit invalidates it at once and a
# sync shows up within CACHE_TTL. An ES failure yields an empty model — pills
# render without numbers instead of breaking the page.
class SavedFilter::Operation::Counts < ApplyMate::Operation::Base
  CACHE_TTL = 5.minutes

  def perform!(saved_filters:, **)
    skip_authorize

    @saved_filters = saved_filters.to_a
    self.model = counts
  end

  private

  def counts
    return {} if @saved_filters.empty?

    Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { fetch_counts }
  rescue StandardError => e
    Rails.logger.error("SavedFilter::Operation::Counts failed: #{e.class}: #{e.message}")
    {}
  end

  def cache_key
    [ 'saved_filter_counts', *@saved_filters.map(&:cache_key_with_version) ]
  end

  def fetch_counts
    responses = Elasticsearch::Model.client.msearch(body: msearch_body)['responses']

    @saved_filters.zip(responses).to_h do |filter, response|
      [ filter.id, response.dig('hits', 'total', 'value').to_i ]
    end
  end

  def msearch_body
    @saved_filters.flat_map { |filter| [ { index: Vacancy.index_name }, count_body(filter) ] }
  end

  def count_body(filter)
    query = run_operation(Vacancy::Operation::BuildSearchQuery,
                          { include_tags: filter.include_tags,
                            include_ops:  filter.include_ops,
                            exclude_tags: filter.exclude_tags }).model

    { query:, size: 0, track_total_hits: true }
  end
end
