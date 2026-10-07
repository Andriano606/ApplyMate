# frozen_string_literal: true

class ApplyStep < ApplicationRecord
  belongs_to :apply

  enum :state, { running: 0, succeeded: 1, failed: 2, skipped: 3 }

  scope :chronological, -> { order(:attempt, :position) }

  def duration
    return if finished_at.blank?

    finished_at - started_at
  end
end
