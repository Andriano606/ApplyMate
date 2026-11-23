# frozen_string_literal: true

class Feedback::Component::FormModal < ApplyMate::Component::Base
  # Selected-state colour of a rating chip, by the sentiment that rating counts as.
  CHECKED_CLASSES = {
    positive: 'peer-checked:bg-green-600 peer-checked:ring-green-600',
    neutral: 'peer-checked:bg-amber-500 peer-checked:ring-amber-500',
    negative: 'peer-checked:bg-red-600 peer-checked:ring-red-600'
  }.freeze

  def initialize(feedback:, **)
    @feedback = feedback
  end

  private

  def scope
    @feedback.persisted? ? 'edit' : 'new'
  end

  def body_input_html
    { rows: 5, maxlength: Feedback::BODY_MAX_LENGTH, placeholder: I18n.t('feedback.form.body_placeholder') }
  end

  def chip_classes(rating)
    'flex h-10 cursor-pointer items-center justify-center rounded-lg text-sm font-semibold ' \
      'bg-white text-gray-700 ring-1 ring-inset ring-gray-300 transition-colors hover:bg-gray-50 ' \
      'peer-checked:text-white peer-focus-visible:outline peer-focus-visible:outline-2 ' \
      'peer-focus-visible:outline-offset-2 peer-focus-visible:outline-indigo-600 ' \
      "dark:bg-gray-800 dark:text-gray-200 dark:ring-gray-600 #{CHECKED_CLASSES.fetch(Feedback.sentiment_for(rating))}"
  end

  def rating_error
    @feedback.errors[:rating].first
  end
end
