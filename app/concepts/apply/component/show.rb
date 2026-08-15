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

  SKIP_MANUAL_TYPES = %w[hidden submit button file].freeze

  # Every answer in copy-ready form. Some sites (Ashby) refuse submissions from
  # automated browsers no matter how well the form is filled — then the only way
  # through is the person's own browser, and all we can do is hand them the
  # answers and the CV so it takes a minute instead of twenty.
  def manual_answers
    Array(@apply.filled_inputs)
      .map { |f| f.to_h.stringify_keys }
      .reject { |f| SKIP_MANUAL_TYPES.include?(f['type']) || f['value'].to_s.strip.empty? }
      .map do |f|
        { question: f['accessible_name'].presence || f['label'].presence || f['name'],
          answer:   human_answer(f) }
      end
  end

  def bookmarklet
    @bookmarklet ||= Apply::Bookmarklet.for(@apply)
  end

  # The stored value is what a form field needs, not what a person reads: a
  # ticked consent is "on" and a chosen option can arrive as "Man=on".
  def human_answer(field)
    value = field['value'].to_s.strip

    case field['type']
    when 'checkbox'
      checked = Apply::FormFiller::CHECKED_VALUES.include?(value.downcase)
      I18n.t(checked ? 'apply.manual.checked' : 'apply.manual.unchecked')
    when 'radio', 'button_group', 'select'
      option_label(field, value) || value.split('=').first.to_s
    else
      value
    end
  end

  def option_label(field, value)
    wanted  = value.downcase.split('=').map(&:strip)
    options = Array(field['options']).map { |o| o.to_h.stringify_keys }

    # Labels first: radio buttons routinely share the value "on", so matching by
    # value would name the wrong option — "Man=on" came back as "Woman".
    by_label = options.find { |o| wanted.include?(o['label'].to_s.downcase.strip) }
    return by_label['label'].presence if by_label

    unique = options.reject { |o| o['value'].to_s.strip.empty? }
                    .group_by { |o| o['value'].to_s.downcase }
                    .select { |_, group| group.size == 1 }
                    .values.flatten
    unique.find { |o| wanted.include?(o['value'].to_s.downcase) }&.dig('label').presence
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

  # Once a session is open, filling again is a repeat, not the main action —
  # it stays available (tabs get lost to restarts) but steps back visually.
  def assisted_button_label
    I18n.t(@apply.awaiting_manual_submit? ? 'apply.assisted.refill' : 'apply.assisted.open')
  end

  def assisted_button_class
    base = 'inline-flex items-center justify-center rounded-lg text-sm px-4 py-2 font-medium '
    return "#{base}bg-blue-600 text-white hover:bg-blue-700" unless @apply.awaiting_manual_submit?

    "#{base}border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-200 " \
      'hover:bg-gray-50 dark:hover:bg-gray-700'
  end

  # Open fields the user is asked to answer: fillable, still blank, not files.
  def review_fields
    Array(@apply.review_fields)
      .map { |f| f.to_h.stringify_keys }
      .reject { |f| %w[file hidden].include?(f['type']) || f['value'].present? }
  end
end
