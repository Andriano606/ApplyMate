# frozen_string_literal: true

# How far a participant has read a feedback thread (see FeedbackReply.unread_for).
class FeedbackThreadRead < ApplicationRecord
  belongs_to :user
  belongs_to :feedback

  # Moves the user's read marks forward ({ feedback_id => seen_at }); never
  # backwards, even when two requests race (GREATEST runs SQL-side).
  def self.mark_seen!(user, seen_at_by_feedback_id)
    return if seen_at_by_feedback_id.empty?

    now = Time.current
    rows = seen_at_by_feedback_id.map do |feedback_id, seen_at|
      { user_id: user.id, feedback_id:, seen_at:, created_at: now, updated_at: now }
    end
    upsert_all(rows, unique_by: %i[user_id feedback_id],
                     on_duplicate: Arel.sql('seen_at = GREATEST(feedback_thread_reads.seen_at, EXCLUDED.seen_at), ' \
                                            'updated_at = EXCLUDED.updated_at'))
  end
end
