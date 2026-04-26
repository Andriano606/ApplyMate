# frozen_string_literal: true

class Apply::Component::Show < ApplyMate::Component::Base
  def initialize(apply:, **)
    @apply = apply
  end

  private

  def header_opts
    { title: I18n.t('apply.show.title'), back_link: helpers.applies_path, back_text: I18n.t('apply.show.back') }
  end

  def card_class
    'bg-white dark:bg-gray-800 rounded-xl border border-gray-200 ' \
      'dark:border-gray-700 divide-y divide-gray-200 dark:divide-gray-700'
  end

  def ai_integration_label
    "#{@apply.ai_integration.provider.capitalize} (#{@apply.ai_integration.model})"
  end

  def error_text_class
    'text-sm text-gray-700 dark:text-gray-300 bg-red-50 ' \
      'dark:bg-red-900/20 rounded-lg p-3 font-mono whitespace-pre-wrap'
  end
end
