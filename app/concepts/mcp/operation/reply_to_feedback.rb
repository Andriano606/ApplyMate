# frozen_string_literal: true

# Posts a message in a feedback thread as the token user: by default under their
# own feedback (usually answering an admin); admins may pass any feedback id.
# Wraps FeedbackReply::Operation::Create, so the web form's rules apply.
class Mcp::Operation::ReplyToFeedback < ApplyMate::Operation::Base
  include Mcp::Operation::FeedbackLookup

  def perform!(params:, current_user:, **)
    feedback = find_feedback(params[:feedback_id], current_user)
    return if feedback.nil?
    return unless authorize_for_tool(FeedbackReply.new(feedback:, user: current_user), :create?, current_user,
                                     I18n.t('mcp.errors.reply_forbidden'))

    sub_result = run_operation(FeedbackReply::Operation::Create,
                               { params: { feedback_id: feedback.id, feedback_reply: { body: params[:comment] } },
                                 current_user:, manually_handle_errors: true })
    if sub_result.failure?
      add_error(:invalid, sub_result.model.errors.full_messages.join('. '))
      raise ActiveRecord::RecordInvalid
    end

    self.model = feedback.reload
  end
end
