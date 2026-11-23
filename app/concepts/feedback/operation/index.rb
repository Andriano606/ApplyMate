# frozen_string_literal: true

# The public feedback page (and MCP list_feedback): everyone's reviews with their
# reply threads (newest edit first, optionally only positive / neutral / negative
# ones), the rating summary and the viewer's own review, which is pinned above
# the list instead of repeated in it. Marks the viewer's unread replies as seen.
class Feedback::Operation::Index < ApplyMate::Operation::Base
  PER_PAGE = 20
  PRELOAD = [ { user: { avatar_attachment: :blob } }, { replies: { user: { avatar_attachment: :blob } } } ].freeze

  def perform!(params:, current_user:, **)
    authorize! Feedback, :index?

    sentiment = params[:sentiment].to_s.to_sym
    sentiment = nil unless Feedback::SENTIMENTS.key?(sentiment)

    own_feedback = (Feedback.includes(PRELOAD).find_by(user: current_user) if current_user)

    self.model = ApplyMate::Operation::Struct.new(
      feedbacks: feedbacks(sentiment, params[:page], current_user),
      own_feedback:,
      new_reply_ids: see_new_replies(own_feedback),
      stats: stats,
      sentiment:,
      viewer: current_user
    )
  end

  private

  # Viewing the page (or listing feedback over MCP) is reading your thread:
  # returns the replies that were new, to highlight them once, and clears the navbar badge.
  def see_new_replies(own_feedback)
    return [] unless own_feedback

    own_feedback.read_new_replies!
  end

  def feedbacks(sentiment, page, current_user)
    scope = Feedback.includes(PRELOAD).order(updated_at: :desc) # index_feedbacks_on_updated_at
    scope = scope.where.not(user: current_user) if current_user
    scope = scope.with_sentiment(sentiment) if sentiment
    scope.paginate(page:, per_page: PER_PAGE)
  end

  # One feedback per user keeps the table as small as the user list; a single
  # grouped query (≤ 10 rows) feeds the whole summary.
  def stats
    by_rating = Feedback.group(:rating).count
    total = by_rating.values.sum
    by_sentiment = Feedback::SENTIMENTS.keys.index_with do |sentiment|
      by_rating.sum { |rating, count| Feedback.sentiment_for(rating) == sentiment ? count : 0 }
    end

    {
      total:,
      average: (by_rating.sum { |rating, count| rating * count }.fdiv(total).round(1) if total.positive?),
      by_sentiment:
    }
  end
end
