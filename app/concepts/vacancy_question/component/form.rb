# frozen_string_literal: true

class VacancyQuestion::Component::Form < ApplyMate::Component::Base
  def initialize(form:, **)
    @form = form
  end
end
