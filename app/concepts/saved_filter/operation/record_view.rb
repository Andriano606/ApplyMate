# frozen_string_literal: true

# Marks a preset as "seen" when the user is actually looking at its results:
# the on-screen state equals the preset and this is the first page (which,
# sorted by vacancy_id desc, also carries the max id — so the snapshot costs
# no extra query). Run by both index operations (vacancies and home).
class SavedFilter::Operation::RecordView < ApplyMate::Operation::Base
  def perform!(saved_filter:, vacancies:, include_tags:, include_ops:, exclude_tags:, **)
    skip_authorize

    self.model = saved_filter
    return if saved_filter.nil?
    return unless vacancies.current_page == 1
    return unless saved_filter.matches_state?(include_tags:, include_ops:, exclude_tags:)

    saved_filter.record_view!(count: vacancies.total_entries, max_vacancy_id: vacancies.first&.id)
  end
end
