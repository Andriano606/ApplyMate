# frozen_string_literal: true

class SavedFilter < ApplicationRecord
  belongs_to :user

  jsonb_accessor :vacancy_search,
                 include_tags: [ :string, array: true, default: [] ],
                 include_ops: [ :string, array: true, default: [] ],
                 exclude_tags: [ :string, array: true, default: [] ]

  validates :name, presence: true, uniqueness: { scope: :user_id }

  # Both the pills row and the search bar ask "is this preset exactly what is on
  # screen right now?" — keep that comparison in one place.
  def matches_state?(include_tags:, include_ops:, exclude_tags:)
    self.include_tags == Array(include_tags) &&
      self.include_ops == Array(include_ops) &&
      self.exclude_tags == Array(exclude_tags)
  end

  # Snapshot for the "+appeared/−disappeared since last view" badges. On an
  # empty result max_vacancy_id is nil — keep the previous watermark so newer
  # vacancies still count as appeared.
  def record_view!(count:, max_vacancy_id:)
    max_vacancy_id ||= last_seen_max_vacancy_id
    return if last_seen_count == count && last_seen_max_vacancy_id == max_vacancy_id

    update!(last_seen_count: count, last_seen_max_vacancy_id: max_vacancy_id)
  end

  def viewed?
    last_seen_count.present?
  end
end
