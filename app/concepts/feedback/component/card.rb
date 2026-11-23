# frozen_string_literal: true

# One review: author, 1–10 rating coloured by sentiment, text and where it was posted from.
class Feedback::Component::Card < ApplyMate::Component::Base
  RATING_CLASSES = {
    positive: 'bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-300',
    neutral: 'bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300',
    negative: 'bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-300'
  }.freeze

  # framed: false drops the card chrome when it sits inside another panel.
  def initialize(feedback:, framed: true)
    @feedback = feedback
    @framed = framed
  end

  private

  attr_reader :feedback

  def wrapper_classes
    @framed ? 'rounded-lg bg-white p-4 shadow dark:bg-gray-800' : ''
  end

  def rating_classes
    "inline-flex shrink-0 items-center rounded-full px-2.5 py-1 text-sm font-semibold #{RATING_CLASSES.fetch(feedback.sentiment)}"
  end

  def sentiment_label
    I18n.t("feedback.sentiments.#{feedback.sentiment}")
  end

  def date
    helpers.l(feedback.updated_at.to_date, format: :long)
  end
end
