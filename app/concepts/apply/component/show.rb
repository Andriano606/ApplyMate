# frozen_string_literal: true

class Apply::Component::Show < ApplyMate::Component::Base
  def initialize(apply:, **)
    @apply = apply
  end

  private

  def header_opts
    { title: I18n.t('apply.show.title'), back_link: helpers.applies_path, back_text: I18n.t('apply.show.back') }
  end

  def error_text_class
    'text-sm text-gray-700 dark:text-gray-300 bg-red-50 ' \
      'dark:bg-red-900/20 rounded-lg p-3 font-mono whitespace-pre-wrap'
  end

  # Offered whenever automation stopped short but the answers exist — the user
  # can have the form typed out for them and just press submit.
  def assisted_available?
    @apply.filled_inputs.present? &&
      (@apply.awaiting_manual_submit? || @apply.needs_review? || @apply.blocked? || @apply.failed?)
  end

  def viewer_url
    ApplyMate::Client::Browser.viewer_url
  end

  # Open fields the user is asked to answer: fillable, still blank, not files.
  def review_fields
    Array(@apply.review_fields)
      .map { |f| f.to_h.stringify_keys }
      .reject { |f| %w[file hidden].include?(f['type']) || f['value'].present? }
  end
end
