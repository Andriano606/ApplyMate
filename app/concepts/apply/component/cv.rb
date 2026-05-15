# frozen_string_literal: true

class Apply::Component::Cv < ApplyMate::Component::Base
  TAB_BASE     = 'border-b-2 px-3 pb-3 pt-1 text-sm font-medium whitespace-nowrap transition-colors'
  TAB_ACTIVE   = 'border-indigo-600 text-indigo-600 dark:border-indigo-400 dark:text-indigo-400'
  TAB_INACTIVE = 'border-transparent text-gray-500 dark:text-gray-400 hover:text-gray-700 hover:border-gray-300'

  def initialize(apply:, cv_tab: :preview, **)
    @apply  = apply
    @cv_tab = cv_tab
  end

  private

  def cv_tab_class(tab)
    "#{TAB_BASE} #{@cv_tab == tab ? TAB_ACTIVE : TAB_INACTIVE}"
  end
end
