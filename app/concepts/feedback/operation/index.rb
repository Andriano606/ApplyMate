# frozen_string_literal: true

# The public feedback page (and MCP list_feedback): everyone's reviews with their
# reply threads (newest edit first; optionally only one sentiment, or only the
# threads with replies the viewer has not read), the rating summary and the
# viewer's own review, pinned above the list instead of repeated in it.
# Showing a thread reads it: its new replies are returned once (highlighted)
# and stop counting for the navbar badge.
class Feedback::Operation::Index < ApplyMate::Operation::Base
  PER_PAGE = 20
  PRELOAD = [ { user: { avatar_attachment: :blob } }, { replies: { user: { avatar_attachment: :blob } } } ].freeze

  def perform!(params:, current_user:, **)
    authorize! Feedback, :index?

    sentiment = params[:sentiment].to_s.to_sym
    sentiment = nil unless Feedback::SENTIMENTS.key?(sentiment)
    unread = current_user.present? && params[:unread].to_s == '1'

    own_feedback = (Feedback.includes(PRELOAD).find_by(user: current_user) if current_user)
    feedbacks = feedbacks(sentiment:, unread:, page: params[:page], current_user:)
    unread_threads = (current_user ? FeedbackReply.unread_for(current_user).distinct.count(:feedback_id) : 0)

    self.model = ApplyMate::Operation::Struct.new(
      feedbacks:,
      own_feedback:,
      unread_threads:,
      # Last: marking read must not change what the queries above returned.
      new_reply_ids: FeedbackReply.read_unread!(current_user, [ own_feedback&.id, *feedbacks.map(&:id) ].compact),
      stats: stats,
      sentiment:,
      unread:,
      viewer: current_user
    )
  end

  private

  # Loaded (rows and total) before the threads are marked read below.
  def feedbacks(sentiment:, unread:, page:, current_user:)
    scope = Feedback.includes(PRELOAD).order(updated_at: :desc) # index_feedbacks_on_updated_at
    scope = scope.where.not(user: current_user) if current_user
    scope = scope.with_sentiment(sentiment) if sentiment
    scope = scope.where(id: FeedbackReply.unread_for(current_user).select(:feedback_id)) if unread
    scope.paginate(page:, per_page: PER_PAGE).tap { |collection| collection.load && collection.total_entries }
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
