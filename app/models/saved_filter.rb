# frozen_string_literal: true

class SavedFilter < ApplicationRecord
  belongs_to :user

  jsonb_accessor :vacancy_search,
                 include_tags: [ :string, array: true, default: [] ],
                 include_ops: [ :string, array: true, default: [] ],
                 exclude_tags: [ :string, array: true, default: [] ]

  validates :name, presence: true, uniqueness: { scope: :user_id }
end
