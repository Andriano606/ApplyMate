# frozen_string_literal: true

# The public feedback page: rating summary with the sentiment split, the
# viewer's own review (or a call to write one) and everyone else's reviews.
class Feedback::Component::Index < ApplyMate::Component::Base
  SENTIMENT_COLORS = {
    positive: { bar: 'bg-green-500', dot: 'bg-green-500' },
    neutral: { bar: 'bg-amber-400', dot: 'bg-amber-400' },
    negative: { bar: 'bg-red-500', dot: 'bg-red-500' }
  }.freeze

  OWN_TITLE_CLASSES = 'text-xs font-semibold uppercase tracking-wide text-indigo-600 dark:text-indigo-400'
  CTA_CLASSES = 'flex flex-col gap-4 rounded-xl bg-indigo-50 p-5 ring-1 ring-indigo-100 sm:flex-row sm:items-center ' \
                'md:p-6 dark:bg-indigo-950/40 dark:ring-indigo-900'
  CTA_ICON_CLASSES = 'hidden h-11 w-11 shrink-0 items-center justify-center rounded-full bg-white text-indigo-600 ' \
                     'shadow-sm sm:flex dark:bg-gray-800'

  def initialize(feedbacks:, own_feedback:, stats:, sentiment:, viewer:, new_reply_ids: [], unread: false,
                 unread_threads: 0, **)
    @feedbacks = feedbacks
    @own_feedback = own_feedback
    @new_reply_ids = new_reply_ids
    @unread = unread
    @unread_threads = unread_threads
    @stats = stats
    @sentiment = sentiment
    @viewer = viewer
  end

  private

  def sentiments
    Feedback::SENTIMENTS.keys
  end

  def count(sentiment)
    @stats[:by_sentiment][sentiment]
  end

  def share(sentiment)
    @stats[:total].positive? ? (count(sentiment) * 100.0 / @stats[:total]).round : 0
  end

  def total_label
    I18n.t('feedback.index.total', count: @stats[:total])
  end

  def average
    return '—' unless @stats[:average]

    helpers.number_with_precision(@stats[:average], precision: 1, strip_insignificant_zeros: true) # uk: "7,5"
  end

  def filter_label(sentiment)
    I18n.t("feedback.index.filters.#{sentiment || :all}")
  end

  def filter_link_options(sentiment)
    active = !@unread && sentiment == @sentiment
    { class: filter_classes(active), data: { test_id: "feedback-filter-#{sentiment || :all}" },
      'aria-current': ('page' if active) }
  end

  # Threads with replies the viewer has not read (the navbar badge links here).
  # Prefetch off: showing a thread marks it read.
  def unread_link_options
    { class: filter_classes(@unread), 'aria-current': ('page' if @unread),
      data: { test_id: 'feedback-filter-unread', turbo_prefetch: false } }
  end

  # The list leaves out the viewer's own review, so its pills do too
  # (the summary above still counts every review).
  def filter_count(sentiment)
    total = sentiment ? count(sentiment) : @stats[:total]
    own_counted = @own_feedback && (sentiment.nil? || @own_feedback.sentiment == sentiment)
    own_counted ? total - 1 : total
  end

  def filter_classes(active)
    base = 'inline-flex min-h-11 items-center gap-1.5 rounded-full px-4 text-sm font-medium transition-colors ' \
           'sm:min-h-0 sm:px-3 sm:py-1.5'
    if active
      "#{base} bg-indigo-600 text-white shadow-sm"
    else
      "#{base} bg-white text-gray-700 ring-1 ring-inset ring-gray-200 hover:bg-gray-50 " \
        'dark:bg-gray-800 dark:text-gray-300 dark:ring-gray-700 dark:hover:bg-gray-700'
    end
  end

  def edit_link_options
    { label: I18n.t('feedback.index.edit'), url: helpers.edit_feedback_path(@own_feedback),
      variant: :outline, size: :sm, class: 'min-h-11 min-w-11 gap-1.5 sm:min-h-0 sm:min-w-0',
      'aria-label': I18n.t('feedback.index.edit'), data: { turbo_stream: true } }
  end

  # Guests are sent to the sign-in modal instead of the feedback form.
  def cta_link_options
    label, url = if @viewer
                   [ I18n.t('feedback.index.new'), helpers.new_feedback_path ]
    else
                   [ I18n.t('navbar.sign_in'), helpers.login_path ]
    end
    { label:, url:, variant: :primary, class: 'shrink-0 justify-center', data: { turbo_stream: true } }
  end

  def cta_hint
    @viewer ? I18n.t('feedback.index.cta_hint') : I18n.t('feedback.index.cta_guest')
  end

  def paginate?
    @feedbacks.total_pages > 1
  end

  def empty_state
    title = if @unread
              I18n.t('feedback.index.empty_unread')
    elsif @sentiment
              I18n.t('feedback.index.empty_filtered')
    elsif @own_feedback
              I18n.t('feedback.index.empty_others')
    else
              I18n.t('feedback.index.empty')
    end
    ApplyMate::Component::EmptyState.new(icon: :chat_bubble, title:, hint: I18n.t('feedback.index.empty_hint'))
  end
end
