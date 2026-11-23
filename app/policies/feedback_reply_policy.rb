# frozen_string_literal: true

# The thread under a feedback is a conversation between admins and the
# feedback's author; everyone else only reads it.
class FeedbackReplyPolicy < ApplicationPolicy
  def create?
    return false unless user

    user.admin? || record.feedback.user_id == user.id
  end
end
