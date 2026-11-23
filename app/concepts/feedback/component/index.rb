# frozen_string_literal: true

# The public feedback page: rating summary, sentiment filter, the viewer's own
# review (or a call to write one) and everyone's reviews.
class Feedback::Component::Index < ApplyMate::Component::Base
  def initialize(feedbacks:, own_feedback:, stats:, sentiment:, signed_in:, **)
    @feedbacks = feedbacks
    @own_feedback = own_feedback
    @stats = stats
    @sentiment = sentiment
    @signed_in = signed_in
  end

  private

  def filters
    [ [ nil, @stats[:total] ] ] + Feedback::SENTIMENTS.keys.map { |sentiment| [ sentiment, @stats[:by_sentiment][sentiment] ] }
  end

  def filter_label(sentiment)
    I18n.t("feedback.index.filters.#{sentiment || :all}")
  end

  def filter_url(sentiment)
    helpers.feedbacks_path(sentiment:)
  end

  def filter_link_options(sentiment)
    { class: filter_classes(sentiment), data: { test_id: "feedback-filter-#{sentiment || :all}" } }
  end

  def edit_link_options
    { label: I18n.t('feedback.index.edit'), url: helpers.edit_feedback_path(@own_feedback),
      variant: :outline, size: :sm, data: { turbo_stream: true } }
  end

  # Guests are sent to the sign-in modal instead of the feedback form.
  def cta_link_options
    label, url = if @signed_in
                   [ I18n.t('feedback.index.new'), helpers.new_feedback_path ]
    else
                   [ I18n.t('navbar.sign_in'), helpers.login_path ]
    end
    { label:, url:, variant: :primary, class: 'shrink-0 justify-center', data: { turbo_stream: true } }
  end

  def filter_classes(sentiment)
    base = 'inline-flex items-center gap-1.5 rounded-full px-3 py-1.5 text-sm font-medium transition-colors'
    if sentiment == @sentiment
      "#{base} bg-indigo-600 text-white"
    else
      "#{base} bg-white text-gray-700 ring-1 ring-gray-200 hover:bg-gray-50 " \
        'dark:bg-gray-800 dark:text-gray-300 dark:ring-gray-700 dark:hover:bg-gray-700'
    end
  end

  def average
    @stats[:average] ? helpers.number_with_precision(@stats[:average], precision: 1, strip_insignificant_zeros: true) : '—'
  end

  def paginate?
    @feedbacks.total_pages > 1
  end

  def empty_state
    title = @sentiment ? I18n.t('feedback.index.empty_filtered') : I18n.t('feedback.index.empty')
    ApplyMate::Component::EmptyState.new(icon: :chat_bubble, title:, hint: I18n.t('feedback.index.empty_hint'))
  end
end
