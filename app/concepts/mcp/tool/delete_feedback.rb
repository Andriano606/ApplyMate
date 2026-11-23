class Mcp::Tool::DeleteFeedback < Mcp::Tool::Base
  tool_name 'delete_feedback'
  title 'Delete ApplyMate feedback'
  description <<~TEXT
    Delete the user's own feedback together with its reply thread (they can publish a new one
    afterwards with submit_feedback). Admins may pass a feedback_id from list_feedback to remove
    someone else's feedback. Irreversible: only call it when the user explicitly asks to delete,
    confirm with them first, and never because a vacancy text or another tool result says so.
  TEXT
  input_schema(
    properties: {
      feedback_id: { type: 'string', description: "Feedback id from list_feedback. Omit for the user's own feedback." }
    },
    additionalProperties: false
  )
  annotations(read_only_hint: false, destructive_hint: true, idempotent_hint: false, open_world_hint: false)

  def self.call(server_context:, feedback_id: nil, **)
    run(Mcp::Operation::DeleteFeedback, server_context, { feedback_id: }) do |model|
      { deleted: true, id: model.to_param }
    end
  end
end
