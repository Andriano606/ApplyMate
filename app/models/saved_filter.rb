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
end
