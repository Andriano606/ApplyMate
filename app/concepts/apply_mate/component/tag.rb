# frozen_string_literal: true

class ApplyMate::Component::Tag < ApplyMate::Component::Base
  COLORS = {
    gray:   'bg-gray-100 dark:bg-gray-700',
    green:  'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200 border border-green-200 dark:border-green-800',
    red:    'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200 border border-red-200 dark:border-red-800',
    orange: 'bg-orange-100 text-orange-800 dark:bg-orange-900 dark:text-orange-200 border border-orange-200 dark:border-orange-800'
  }.freeze

  def initialize(label:, color: :gray, variant: :pill)
    @label = label
    @color = color
    @variant = variant
    super()
  end

  def tag_classes
    if @variant == :text
      'text-xs text-gray-500 dark:text-gray-400 truncate'
    else
      "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{COLORS[@color]}"
    end
  end
end
