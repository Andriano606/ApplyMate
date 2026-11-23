# frozen_string_literal: true

# A user's review of ApplyMate: one per user, editable, posted from the web page
# or by Claude through the MCP tool submit_feedback (see .ai/docs/feedback.md).
class Feedback < ApplicationRecord
  RATINGS = (1..10)
  BODY_MAX_LENGTH = 2000
  SENTIMENTS = { positive: 7..10, neutral: 5..6, negative: 1..4 }.freeze
  POSTED_VIA = %w[web mcp].freeze

  belongs_to :user

  validates :rating, presence: true, inclusion: { in: RATINGS }
  validates :body, presence: true, length: { maximum: BODY_MAX_LENGTH }
  validates :posted_via, inclusion: { in: POSTED_VIA }
  validate :one_per_user, on: :create

  scope :with_sentiment, ->(sentiment) { where(rating: SENTIMENTS.fetch(sentiment)) }

  def self.sentiment_for(rating)
    SENTIMENTS.find { |_sentiment, range| range.cover?(rating) }&.first
  end

  def sentiment
    self.class.sentiment_for(rating)
  end

  def via_mcp?
    posted_via == 'mcp'
  end

  def edited?
    updated_at - created_at > 1.minute
  end

  private

  # The unique index on user_id is the real guarantee; this turns the common
  # case into a readable error instead of RecordNotUnique.
  def one_per_user
    return unless user_id && Feedback.exists?(user_id:)

    errors.add(:base, I18n.t('feedback.errors.already_exists'))
  end
end
