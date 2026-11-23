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
  validate :thread_not_full, on: :create

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
