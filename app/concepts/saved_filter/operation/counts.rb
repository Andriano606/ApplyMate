# frozen_string_literal: true

# Per-preset counters for the pills row (result model): how many vacancies
# match now, and how many appeared/disappeared since the user last viewed the
# preset.
#
# One ES msearch covers all presets (count + appeared per preset). Counts move
# only when a sync run inserts vacancies or a preset changes, so they are
# cached; the key includes the presets' cache versions, which change on every
# edit and on every recorded view (updated_at), invalidating exactly when the
# numbers should. An ES failure yields an empty model — pills render without
# numbers instead of breaking the page.
class SavedFilter::Operation::Counts < ApplyMate::Operation::Base
  CACHE_TTL = 5.minutes

  Stat = Struct.new(:count, :appeared, :disappeared)

  # model: { saved_filter.id => Stat }; appeared/disappeared are nil until first view
  def perform!(saved_filters:, **)
    skip_authorize

    @saved_filters = saved_filters.to_a
    self.model = stats
  end

  private

  def stats
    return {} if @saved_filters.empty?

    counts = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { fetch_counts }

    @saved_filters.each_with_object({}) do |filter, stats|
      count, appeared = counts[filter.id]
      next if count.nil?

      stats[filter.id] = build_stat(filter, count, appeared)
    end
  rescue StandardError => e
    Rails.logger.error("SavedFilter::Operation::Counts failed: #{e.class}: #{e.message}")
    {}
  end

  def build_stat(filter, count, appeared)
    return Stat.new(count, nil, nil) unless filter.viewed?

    disappeared = [ filter.last_seen_count + appeared - count, 0 ].max
    Stat.new(count, appeared, disappeared)
  end

  def cache_key
    # cache_key_with_version ties the entry to each preset's updated_at, which
    # changes on every edit and every recorded view
    [ 'saved_filter_counts', *@saved_filters.map(&:cache_key_with_version) ]
  end

  # => { filter.id => [count, appeared] }
  def fetch_counts
    responses = Elasticsearch::Model.client.msearch(body: msearch_body)['responses']

    @saved_filters.each_with_index.to_h do |filter, index|
      count    = total_of(responses[2 * index])
      appeared = filter.viewed? ? total_of(responses[2 * index + 1]) : nil
      [ filter.id, [ count, appeared ] ]
    end
  end

  def msearch_body
    @saved_filters.flat_map do |filter|
      [
        { index: Vacancy.index_name }, count_body(filter),
        { index: Vacancy.index_name }, count_body(filter, min_vacancy_id: filter.last_seen_max_vacancy_id || 0)
      ]
    end
  end

  def count_body(filter, min_vacancy_id: nil)
    query = run_operation(Vacancy::Operation::BuildSearchQuery,
                          { include_tags: filter.include_tags,
                            include_ops:  filter.include_ops,
                            exclude_tags: filter.exclude_tags,
                            min_vacancy_id: }).model

    { query:, size: 0, track_total_hits: true }
  end

  def total_of(response)
    response.dig('hits', 'total', 'value').to_i
  end
end
