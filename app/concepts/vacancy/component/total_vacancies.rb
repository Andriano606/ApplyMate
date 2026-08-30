# frozen_string_literal: true

class Vacancy::Component::TotalVacancies < ApplyMate::Component::Base
  # One grouped scan instead of a COUNT per source, cached because the numbers
  # only move when a sync run inserts vacancies — 5 minutes of staleness is fine
  COUNTS_CACHE_KEY = 'vacancy_counts_by_source_id'
  COUNTS_TTL = 5.minutes

  private

  def total_vacancies
    @total_vacancies ||= begin
      counts = Rails.cache.fetch(COUNTS_CACHE_KEY, expires_in: COUNTS_TTL) { Vacancy.group(:source_id).count }
      Source.all.map { |source| ApplyMate::Operation::Struct.new(source:, count: counts[source.id].to_i) }
    end
  end

  def total_count
    total_vacancies.sum(&:count)
  end
end
