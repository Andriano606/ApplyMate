# frozen_string_literal: true

# Adds a message to the thread under a feedback (admins anywhere, the author in
# their own thread). Also behind the MCP tool reply_to_feedback.
class FeedbackReply::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    feedback = Feedback.find(params[:feedback_id])
    self.model = feedback.replies.build(user: current_user, body: params.dig(:feedback_reply, :body))
    authorize! model, :create?

    model.save!
    notice(I18n.t('feedback_reply.create.success'))
  end
end
