# frozen_string_literal: true

# A feedback as the MCP tools return it, with the thread under it (admins'
# answers and the author's replies) so Claude can relay the conversation.
# with_author: adds the author's name (lists of other people's feedback);
# new_reply_ids: replies to flag `new: true` (unread by the author).
class Feedback::Serializer::Detail < ApplyMate::Serializer::Base
  def self.call(model, with_author: false, new_reply_ids: [])
    new(model).call(with_author:, new_reply_ids:)
  end

  def call(with_author: false, new_reply_ids: [])
    payload = {
      id: @model.to_param,
      rating: @model.rating,
      sentiment: @model.sentiment,
      comment: @model.body,
      posted_via: @model.posted_via,
      created_at: @model.created_at,
      updated_at: @model.updated_at,
      replies: @model.replies.map { |reply| reply_payload(reply, new_reply_ids) }
    }
    with_author ? { author: @model.user.name }.merge(payload) : payload
  end

  private

  def reply_payload(reply, new_reply_ids)
    {
      author: reply.user.name,
      role: reply.role,
      comment: reply.body,
      created_at: reply.created_at,
      new: new_reply_ids.include?(reply.id)
    }
  end
end
