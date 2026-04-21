# frozen_string_literal: true

class ApplyMate::Component::BooleanLink < ApplyMate::Component::Base
  def initialize(form:, name:, label: nil, icon: nil, **options)
    @form = form
    @name = name
    @label = label
    @icon = icon
    @options = options
    super()
  end
end
