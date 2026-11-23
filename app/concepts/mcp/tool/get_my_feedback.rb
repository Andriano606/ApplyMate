class Mcp::Tool::GetMyFeedback < Mcp::Tool::Base
  tool_name 'get_my_feedback'
  title 'Get my ApplyMate feedback'
  description <<~TEXT
    The user's own published feedback about ApplyMate (rating 1–10 and comment), or
    feedback: null when they have not left one yet. Read it before submit_feedback when the
    user wants to amend their review rather than replace it.
  TEXT
  input_schema(properties: {}, additionalProperties: false)
  annotations(**READ_ONLY)

  def self.call(server_context:, **)
    run(Mcp::Operation::GetMyFeedback, server_context) do |model|
      { feedback: model && Feedback::Serializer::Detail.call(model) }
    end
  end
end
