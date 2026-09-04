# frozen_string_literal: true

class Vacancy::Component::Card < ApplyMate::Component::Base
  def initialize(vacancy:, apply: nil, hidden: false)
    @vacancy = vacancy
    @apply = apply
    @hidden = hidden
  end

  private

  def hidden?
    @hidden
  end

  def card_classes
    base = 'bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 ' \
           'flex flex-col h-80 transition'
    hidden? ? "#{base} blur-sm opacity-60 pointer-events-none select-none" : base
  end

  # Hidden until hover only where a hover exists (Tailwind gates `group-hover` on
  # `@media (hover: hover)`); touch devices always see the restore button.
  def overlay_classes
    'absolute inset-0 flex flex-col items-center justify-center gap-2 rounded-xl transition-opacity ' \
      '[@media(hover:hover)]:opacity-0 group-hover:opacity-100 focus-within:opacity-100'
  end

  def hide_path
    helpers.vacancy_hidden_vacancy_path(@vacancy)
  end

  def description
    sanitized = ActionController::Base.helpers.strip_tags(@vacancy.description)
    truncate(sanitized, length: 300, separator: ' ')
  end

  def valid_icon_url?
    return false unless @vacancy.company_icon_url.present?

    uri = URI.parse(@vacancy.company_icon_url)
    uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
  rescue URI::InvalidURIError
    false
  end

  def company_initial
    @vacancy.company_name.to_s.first.upcase
  end
end
