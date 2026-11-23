# frozen_string_literal: true

# One message in the thread under a feedback: written by an admin or by the
# feedback's author (FeedbackReplyPolicy), readable by everyone.
class FeedbackReply < ApplicationRecord
  BODY_MAX_LENGTH = 2000
  # Bounds what the public page and list_feedback load per thread.
  MAX_PER_FEEDBACK = 100

  belongs_to :feedback
  belongs_to :user

  validates :body, presence: true, length: { maximum: BODY_MAX_LENGTH }

  # Replies by others, not seen yet, in the threads `user` takes part in: under
  # their own feedback (unread until a read mark exists) or one they replied in
  # (replying leaves a read mark, see FeedbackReply::Operation::Create).
  # Rides index_feedback_thread_reads_on_user_id_and_feedback_id and
  # index_feedback_replies_on_feedback_id_and_created_at.
  scope :unread_for, lambda { |user|
    reads_join = sanitize_sql_array([ 'LEFT JOIN feedback_thread_reads reads ' \
                                      'ON reads.feedback_id = feedback_replies.feedback_id AND reads.user_id = ?', user.id ])
    joins(:feedback).joins(reads_join)
      .where.not(user_id: user.id)
      .where('feedbacks.user_id = :user_id OR reads.id IS NOT NULL', user_id: user.id)
      .where('reads.seen_at IS NULL OR feedback_replies.created_at > reads.seen_at')
  }
  validate :thread_not_full, on: :create

  # Reads the given threads as `user`: returns the ids of the replies that were
  # new for them (to highlight once) and moves their read marks to the newest of
  # those — not to "now", so a reply committed meanwhile stays unread.
  def self.read_unread!(user, feedback_ids)
    return [] if user.nil? || feedback_ids.empty?

    rows = unread_for(user).where(feedback_id: feedback_ids).pluck(:id, :feedback_id, :created_at)
    seen = rows.group_by(&:second).transform_values { |thread| thread.map(&:third).max }
    FeedbackThreadRead.mark_seen!(user, seen)
    rows.map(&:first)
  end

  # Who wrote it, as shown in the thread and returned over MCP: :admin, :author or nil.
  def role
    if user.admin?
      :admin
    elsif user_id == feedback.user_id
      :author
    end
  end

  private

  def thread_not_full
    return unless feedback && feedback.replies.count >= MAX_PER_FEEDBACK

    errors.add(:base, I18n.t('feedback_reply.errors.thread_full', count: MAX_PER_FEEDBACK))
  end
end
