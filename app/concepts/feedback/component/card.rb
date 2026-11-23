# frozen_string_literal: true

# One review: author, 1–10 rating coloured by sentiment, text, where it was
# posted from, and the reply thread under it.
class Feedback::Component::Card < ApplyMate::Component::Base
  # Extra controls shown beside the rating (the "Edit" button on the viewer's own review).
  renders_many :actions

  RATING_CLASSES = {
    positive: 'bg-green-50 text-green-800 ring-green-600/20 dark:bg-green-900/30 dark:text-green-300',
    neutral: 'bg-amber-50 text-amber-800 ring-amber-600/30 dark:bg-amber-900/30 dark:text-amber-300',
    negative: 'bg-red-50 text-red-800 ring-red-600/20 dark:bg-red-900/30 dark:text-red-300'
  }.freeze

  VIA_MCP_CLASSES = 'mt-3 inline-flex items-center gap-1 rounded-full bg-gray-100 px-2 py-0.5 text-xs text-gray-600 ' \
                    'dark:bg-gray-900/40 dark:text-gray-400'

  DELETE_BUTTON_CLASSES = 'inline-flex min-h-11 min-w-11 items-center justify-center rounded-lg text-gray-400 ' \
                          'transition-colors hover:bg-red-50 hover:text-red-600 sm:min-h-8 sm:min-w-8 ' \
                          'dark:hover:bg-red-900/30'

  # framed: false drops the card chrome when it sits inside another panel.
  # new_reply_ids: replies to highlight as unread (the viewer's own review only).
  def initialize(feedback:, viewer: nil, framed: true, new_reply_ids: [])
    @feedback = feedback
    @viewer = viewer
    @framed = framed
    @new_reply_ids = new_reply_ids
  end

  private

  attr_reader :feedback

  def wrapper_classes
    return '' unless @framed

    'rounded-xl bg-white p-5 shadow-sm ring-1 ring-gray-100 dark:bg-gray-800 dark:ring-gray-700'
  end

  def rating_classes
    'inline-flex shrink-0 items-baseline gap-0.5 rounded-lg px-2.5 py-1 ring-1 ring-inset ' \
      "#{RATING_CLASSES.fetch(feedback.sentiment)}"
  end

  def can_destroy?
    @viewer.present? && FeedbackPolicy.new(@viewer, feedback).destroy?
  end

  def sentiment_label
    I18n.t("feedback.sentiments.#{feedback.sentiment}")
  end

  def date
    helpers.l(feedback.updated_at.to_date, format: :long)
  end
end
