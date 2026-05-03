# frozen_string_literal: true

class ApplyMate::Component::RadioButton < ApplyMate::Component::Base
  def initialize(form:, attribute:, value:, label:, icon_name:, input_html: {})
    @form = form
    @attribute = attribute
    @value = value
    @label = label
    @icon_name = icon_name
    @input_html = input_html
  end

  private

  attr_reader :form, :attribute, :value, :label, :icon_name, :input_html

  def input_options
    input_html.merge(checked: selected?, class: 'sr-only')
  end

  def selected?
    form.object.send(attribute).to_s == value.to_s
  end

  def card_class
    base = 'flex flex-1 flex-col items-center justify-center gap-2 p-4 rounded-xl border-2 ' \
      'cursor-pointer transition-all duration-150 ease-in-out text-center'

    state = if selected?
              'border-indigo-500 bg-indigo-50 dark:bg-indigo-900/20 dark:border-indigo-400'
    else
              'border-gray-200 dark:border-gray-600 bg-white dark:bg-gray-800 ' \
                'hover:border-gray-300 dark:hover:border-gray-500'
    end
    "#{base} #{state}"
  end
end
