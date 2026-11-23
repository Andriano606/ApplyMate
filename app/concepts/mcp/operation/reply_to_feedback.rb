# frozen_string_literal: true

# Posts a message in a feedback thread as the token user: by default under their
# own feedback (usually answering an admin); admins may pass any feedback id.
# Wraps FeedbackReply::Operation::Create, so the web form's rules apply.
class Mcp::Operation::ReplyToFeedback < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    feedback = find_feedback(params[:feedback_id], current_user)
    return if feedback.nil?

    reply = FeedbackReply.new(feedback:, user: current_user)
    return forbidden unless Pundit.policy!(current_user, reply).create?

    authorize! reply, :create?
    sub_result = run_operation(FeedbackReply::Operation::Create,
                               { params: { feedback_id: feedback.id, feedback_reply: { body: params[:comment] } },
                                 current_user:, manually_handle_errors: true })
    if sub_result.failure?
      add_error(:invalid, sub_result.model.errors.full_messages.join('. '))
      raise ActiveRecord::RecordInvalid
    end

    self.model = feedback.reload
  end

  private

  # A readable tool error for Claude instead of an MCP internal error.
  def forbidden
    skip_authorize
    add_error(:forbidden, I18n.t('mcp.errors.reply_forbidden'))
  end

  def find_feedback(id, current_user)
    feedback = id.present? ? Feedback.find_by_hashid(id.to_s) : Feedback.find_by(user: current_user)
    return feedback if feedback

    skip_authorize
    add_error(:not_found, id.present? ? I18n.t('mcp.errors.unknown_feedback', id:) : I18n.t('mcp.errors.no_feedback'))
    nil
  end
end
