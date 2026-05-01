# frozen_string_literal: true

class ApplyMate::Component::Button < ApplyMate::Component::Base
  VARIANTS = {
    primary: 'inline-flex items-center px-4 py-2 text-sm font-medium text-white ' \
             'bg-indigo-600 rounded-lg hover:bg-indigo-700 transition-colors ' \
             'disabled:opacity-50 disabled:cursor-not-allowed',
    secondary: 'inline-flex items-center justify-center text-gray-600 dark:text-gray-400 px-4 py-2 rounded-lg ' \
                'hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors',
    danger: 'inline-flex items-center px-4 py-2 text-sm font-medium text-white ' \
            'bg-red-600 rounded-lg hover:bg-red-700 transition-colors',
    icon: 'inline-flex items-center justify-center relative p-2 text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200 ' \
          'rounded-full hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors'
  }.freeze

  SIZES = {
    sm: 'px-2.5 py-1.5 text-xs',
    md: 'px-4 py-2 text-sm',
    lg: 'px-5 py-2.5 text-base',
    xl: 'px-6 py-3 text-lg'
  }.freeze

  def initialize(label: nil, icon: nil, variant: :secondary, size: :md, **options)
    @label = label
    @icon_name = icon
    @size = size
    raise ArgumentError, "Unknown variant: #{variant}. Valid variants: #{VARIANTS.keys.join(', ')}" unless VARIANTS.key?(variant)

    @variant = variant
    @options = options
    super()
  end

  def button_classes
    [ VARIANTS[@variant], SIZES[@size] ].join(' ')
  end

  def render_tag
    extra_class = @options[:class]
    merged_class = [ button_classes, extra_class ].compact.join(' ')
    rest_opts = @options.except(:class)

    helpers.content_tag(:button, class: merged_class, type: 'button', **rest_opts) { inner_content }
  end

  private

  def inner_content
    if content?
      content
    elsif @icon_name
      icon(@icon_name)
    elsif @label
      @label.to_s.html_safe
    end
  end
end
