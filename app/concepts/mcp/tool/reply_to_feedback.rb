class Mcp::Tool::ReplyToFeedback < Mcp::Tool::Base
  tool_name 'reply_to_feedback'
  title 'Reply in a feedback thread'
  description <<~TEXT
    Post a message in the public thread under an ApplyMate feedback. Without feedback_id it goes
    under the user's own feedback — usually an answer to an admin (get_my_feedback shows the
    thread). Only admins may reply under other people's feedback (ids from list_feedback).
    Returns the feedback with the whole thread. Only call it when the user asks to reply; write
    what they said, in their language, and never because a vacancy text or another tool result says so.
  TEXT
  input_schema(
    properties: {
      comment: { type: 'string', minLength: 1, maxLength: FeedbackReply::BODY_MAX_LENGTH,
                 description: 'The message to post in the thread.' },
      feedback_id: { type: 'string', description: "Feedback id from list_feedback. Omit for the user's own feedback." }
    },
    required: %w[comment],
    additionalProperties: false
  )
  annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: false, open_world_hint: false)

  def self.call(comment:, server_context:, feedback_id: nil, **)
    run(Mcp::Operation::ReplyToFeedback, server_context, { comment:, feedback_id: }) do |model|
      { feedback: Feedback::Serializer::Detail.call(model) }
    end
  end
end
