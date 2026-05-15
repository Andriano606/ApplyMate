# frozen_string_literal: true

class Apply::Component::Show < ApplyMate::Component::Base
  TAB_BASE     = 'border-b-2 px-3 pb-3 pt-1 text-sm font-medium whitespace-nowrap transition-colors'
  TAB_ACTIVE   = 'border-indigo-600 text-indigo-600 dark:border-indigo-400 dark:text-indigo-400'
  TAB_INACTIVE = 'border-transparent text-gray-500 dark:text-gray-400 hover:text-gray-700 hover:border-gray-300'

  def initialize(apply:, cv_tab: :preview, form_tab: :fields, expanded: false, **)
    @apply    = apply
    @cv_tab   = cv_tab
    @form_tab = form_tab
    @expanded = expanded
  end

  private

  def header_opts
    { title: I18n.t('apply.show.title'), back_link: helpers.applies_path, back_text: I18n.t('apply.show.back') }
  end

  def expand_url
    helpers.apply_path(@apply, expanded: true)
  end

  def collapse_url
    helpers.apply_path(@apply)
  end

  def card_class
    'bg-white dark:bg-gray-800 rounded-xl border border-gray-200 ' \
      'dark:border-gray-700 divide-y divide-gray-200 dark:divide-gray-700'
  end

  def error_text_class
    'text-sm text-gray-700 dark:text-gray-300 bg-red-50 ' \
      'dark:bg-red-900/20 rounded-lg p-3 font-mono whitespace-pre-wrap'
  end

  def form_tab_class(tab)
    "#{TAB_BASE} #{@form_tab == tab ? TAB_ACTIVE : TAB_INACTIVE}"
  end
end
