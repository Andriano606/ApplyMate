# frozen_string_literal: true

class ApplyMate::Component::SelectOption < ApplyMate::Component::Base
  def initialize(form:, radio_attribute:, radio_value:, radio_name:, selected:)
    @form            = form
    @radio_attribute = radio_attribute
    @radio_value     = radio_value
    @radio_name      = radio_name
    @selected        = selected
  end

  private

  attr_reader :form, :radio_attribute, :radio_value, :radio_name

  def selected?
    @selected
  end

  def card_class
    base = 'select-option-card flex items-center gap-3 p-3 rounded-xl border-2 ' \
           'transition-all duration-150 ease-in-out'
    state = selected? ? '!border-green-500 !bg-green-50' : 'border-gray-200 bg-white hover:border-gray-300 hover:bg-gray-50'
    "#{base} #{state}"
  end
end
