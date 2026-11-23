# frozen_string_literal: true

# A user's review of ApplyMate: one per user, editable, posted from the web page
# or by Claude through the MCP tool submit_feedback (see .ai/docs/feedback.md).
class Feedback < ApplicationRecord
  RATINGS = (1..10)
  BODY_MAX_LENGTH = 2000
  SENTIMENTS = { positive: 7..10, neutral: 5..6, negative: 1..4 }.freeze
  POSTED_VIA = %w[web mcp].freeze

  belongs_to :user
  has_many :replies, -> { order(:created_at) }, class_name: 'FeedbackReply', dependent: :destroy, inverse_of: :feedback

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

  # Replies by others the author has not seen yet (feedback page or MCP marks them seen).
  def unread_replies
    scope = replies.where.not(user_id:)
    replies_seen_at ? scope.where(FeedbackReply.arel_table[:created_at].gt(replies_seen_at)) : scope
  end

  # Reads the thread as its author: returns the ids of the replies that were new
  # (to highlight once) and moves replies_seen_at to the newest of them — not to
  # "now", so a reply committed meanwhile stays unread.
  def read_new_replies!
    new_replies = unread_replies.pluck(:id, :created_at)
    update_column(:replies_seen_at, new_replies.map(&:last).max) if new_replies.any?
    new_replies.map(&:first)
  end

  def edited?
    updated_at - created_at > 1.hour
  end

  private

  # The unique index on user_id is the real guarantee; this turns the common
  # case into a readable error instead of RecordNotUnique.
  def one_per_user
    return unless user_id && Feedback.exists?(user_id:)

    errors.add(:base, I18n.t('feedback.errors.already_exists'))
  end
end
