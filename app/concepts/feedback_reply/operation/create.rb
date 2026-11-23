# frozen_string_literal: true

# Adds a message to the thread under a feedback (admins anywhere, the author in
# their own thread). Also behind the MCP tool reply_to_feedback.
class FeedbackReply::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    feedback = Feedback.find(params[:feedback_id])
    self.model = feedback.replies.build(user: current_user, body: params.dig(:feedback_reply, :body))
    authorize! model, :create?

    model.save!
    # Replying means having read the thread; it also makes the replier a
    # participant who is told about answers (FeedbackReply.unread_for).
    FeedbackThreadRead.mark_seen!(current_user, { feedback.id => model.created_at })
    notice(I18n.t('feedback_reply.create.success'))
  end
end
