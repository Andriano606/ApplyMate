# frozen_string_literal: true

class ApplyStep < ApplicationRecord
  # Masked screenshots / redacted HTML of a failed attempt (FailureArtifacts); purged by PruneApplySteps.
  MAX_ARTIFACTS_PER_ATTEMPT = 8

  belongs_to :apply

  has_many_attached :artifacts

  enum :state, { running: 0, succeeded: 1, failed: 2, skipped: 3 }

  scope :chronological, -> { order(:attempt, :position) }

  # The artifacts in attach order. URLs address one by its 1-based position in this list (artifact_at), never by the
  # global active_storage_attachments id. At most MAX_ARTIFACTS_PER_ATTEMPT rows per step, so they are loaded whole.
  def ordered_artifacts
    artifacts_attachments.sort_by(&:id)
  end

  # position: a 1-based Integer, or anything else (nil).
  def artifact_at(position)
    ordered_artifacts[position - 1] if position.is_a?(Integer) && position.positive?
  end

  def duration
    return if finished_at.blank?

    finished_at - started_at
  end
end
