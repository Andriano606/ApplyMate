# frozen_string_literal: true

class ApplyMate::Component::BooleanLink < ApplyMate::Component::Base
  def initialize(form:, name:, label: nil, icon: nil, checked: false, index: nil, label_class: nil, **options)
    @form = form
    @name = name
    @label = label
    @icon = icon
    @label_class = "#{label_class}"
    @id = index ? "#{name}_#{index}" : "#{name}_#{SecureRandom.hex(4)}"
    @input_html = { checked:, id: @id, class: 'peer sr-only', **options }
    @input_html[:name] = "#{name}[#{index}]" if index
    super()
  end
end
