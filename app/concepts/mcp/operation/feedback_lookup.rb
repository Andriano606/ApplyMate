# frozen_string_literal: true

# Shared by the MCP feedback operations that act on one feedback: the token
# user's own by default, any by id (the policy then decides), and readable tool
# errors instead of Pundit exceptions, which MCP would turn into an internal error.
module Mcp::Operation::FeedbackLookup
  private

  def find_feedback(id, current_user)
    feedback = id.present? ? Feedback.find_by_hashid(id.to_s) : Feedback.find_by(user: current_user)
    return feedback if feedback

    skip_authorize
    add_error(:not_found, id.present? ? I18n.t('mcp.errors.unknown_feedback', id:) : I18n.t('mcp.errors.no_feedback'))
    nil
  end

  # Authorizes like authorize! but reports a refusal as a tool error; returns false then.
  def authorize_for_tool(record, query, current_user, message)
    if Pundit.policy!(current_user, record).public_send(query)
      authorize! record, query
      true
    else
      skip_authorize
      add_error(:forbidden, message)
      false
    end
  end
end
