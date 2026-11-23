# frozen_string_literal: true

# The public feedback page: everyone's reviews (newest edit first, optionally only
# positive / neutral / negative ones), the rating summary and the viewer's own review.
class Feedback::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    authorize! Feedback, :index?

    sentiment = params[:sentiment].to_s.to_sym
    sentiment = nil unless Feedback::SENTIMENTS.key?(sentiment)

    self.model = ApplyMate::Operation::Struct.new(
      feedbacks: feedbacks(sentiment, params[:page]),
      own_feedback: (Feedback.find_by(user: current_user) if current_user),
      stats: stats,
      sentiment:,
      signed_in: current_user.present?
    )
  end

  private

  def feedbacks(sentiment, page)
    scope = Feedback.includes(user: { avatar_attachment: :blob }).order(updated_at: :desc) # index_feedbacks_on_updated_at
    scope = scope.with_sentiment(sentiment) if sentiment
    scope.paginate(page:, per_page: 20)
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
