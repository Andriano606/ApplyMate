# frozen_string_literal: true

class Vacancy::Component::SearchBar::Tag < ApplyMate::Component::Base
  def initialize(form:, name:, label:, index:)
    @form = form
    @name = name
    @label = label
    @index = index
  end
end
