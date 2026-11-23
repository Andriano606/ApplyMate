# frozen_string_literal: true

# The token user's feedback with its thread; replies they had not seen are
# returned flagged and count as read afterwards (like opening the feedback page).
class Mcp::Operation::GetMyFeedback < ApplyMate::Operation::Base
  def perform!(current_user:, **)
    authorize! Feedback, :index?

    feedback = Feedback.includes(replies: :user).find_by(user: current_user)
    new_reply_ids = feedback ? feedback.read_new_replies! : []

    self.model = ApplyMate::Operation::Struct.new(feedback:, new_reply_ids:)
  end
end
