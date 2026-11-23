class Mcp::Tool::GetMyFeedback < Mcp::Tool::Base
  tool_name 'get_my_feedback'
  title 'Get my ApplyMate feedback'
  description <<~TEXT
    The user's own published feedback about ApplyMate (rating 1–10 and comment) with the thread
    under it (`replies`: admins' answers and the user's own replies, oldest first), or
    feedback: null when they have not left one yet. Read it before submit_feedback when the
    user wants to amend their review rather than replace it, and to see whether an admin answered:
    replies the user had not seen yet are flagged `new: true` (count in `unread_replies`) and count
    as read after this call.
  TEXT
  input_schema(properties: {}, additionalProperties: false)
  annotations(**READ_ONLY)

  def self.call(server_context:, **)
    run(Mcp::Operation::GetMyFeedback, server_context) do |model|
      feedback = model.feedback
      { feedback: feedback && Feedback::Serializer::Detail.call(feedback, new_reply_ids: model.new_reply_ids),
        unread_replies: model.new_reply_ids.size }
    end
  end
end
