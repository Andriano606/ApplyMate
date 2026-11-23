# frozen_string_literal: true

# Deletes the token user's own feedback (with its thread), or — admins only —
# any feedback by id. Wraps Feedback::Operation::Destroy.
class Mcp::Operation::DeleteFeedback < ApplyMate::Operation::Base
  include Mcp::Operation::FeedbackLookup

  def perform!(params:, current_user:, **)
    feedback = find_feedback(params[:feedback_id], current_user)
    return if feedback.nil?
    return unless authorize_for_tool(feedback, :destroy?, current_user, I18n.t('mcp.errors.delete_forbidden'))

    run_operation(Feedback::Operation::Destroy, { params: { id: feedback.id }, current_user: })
    self.model = feedback
  end
end
