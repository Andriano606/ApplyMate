# frozen_string_literal: true

# Live vacancy count per source (result model: { source_id => count }). One
# grouped scan instead of a COUNT per source, cached because the numbers only
# move when a sync run inserts or deletes vacancies — 5 minutes of staleness is
# fine. Shared by the totals widget and the MCP `list_sources` tool.
class Vacancy::Operation::CountBySource < ApplyMate::Operation::Base
  CACHE_KEY = 'vacancy_counts_by_source_id'
  TTL = 5.minutes

  # Called by SyncVacancies once a source's listing is fully persisted (and stale
  # rows deleted) so readers get the new totals right away instead of the
  # previous run's numbers for up to TTL.
  def self.expire!
    Rails.cache.delete(CACHE_KEY)
  end

  def perform!(**)
    skip_authorize

    self.model = Rails.cache.fetch(CACHE_KEY, expires_in: TTL) { Vacancy.group(:source_id).count }
  end
end
