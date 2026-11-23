class Mcp::Tool::ListFeedback < Mcp::Tool::Base
  tool_name 'list_feedback'
  title 'List ApplyMate feedback'
  description <<~TEXT
    The public feedback page: everyone's reviews of ApplyMate (author, rating 1–10, sentiment,
    comment, reply thread), newest edit first, plus the rating summary and the user's own review
    (`own_feedback`, never repeated in `feedbacks`). Filter with sentiment
    (#{Feedback::SENTIMENTS.map { |sentiment, range| "#{sentiment} = #{range.min}–#{range.max}" }.join(', ')}).
    Replies the user had not seen yet — under their own review or in threads they replied in — are
    flagged `new: true` and count as read afterwards; unread_only lists just those threads.
    Admins use the ids with reply_to_feedback and delete_feedback.
  TEXT
  input_schema(
    properties: {
      sentiment: { type: 'string', enum: Feedback::SENTIMENTS.keys.map(&:to_s), description: 'Only this kind of review.' },
      unread_only: { type: 'boolean', description: 'Only threads with replies the user has not read yet.' },
      page: { type: 'integer', minimum: 1, description: "Page number (#{Feedback::Operation::Index::PER_PAGE} per page)." }
    },
    additionalProperties: false
  )
  # Not read-only: it marks the user's unread replies as seen (like opening the page).
  annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

  def self.call(server_context:, sentiment: nil, page: nil, unread_only: false, **)
    run(Feedback::Operation::Index, server_context, { sentiment:, page:, unread: (1 if unread_only) }) do |model|
      new_ids = model.new_reply_ids
      {
        stats: model.stats,
        own_feedback: model.own_feedback && Feedback::Serializer::Detail.call(model.own_feedback, new_reply_ids: new_ids),
        feedbacks: model.feedbacks.map do |feedback|
          Feedback::Serializer::Detail.call(feedback, with_author: true, new_reply_ids: new_ids)
        end,
        pagination: feedback_pagination(model.feedbacks)
      }
    end
  end

  def self.feedback_pagination(collection)
    { page: collection.current_page, total_pages: collection.total_pages, total_entries: collection.total_entries,
      next_page: collection.next_page }
  end
  private_class_method :feedback_pagination
end
