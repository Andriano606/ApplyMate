# frozen_string_literal: true

class Vacancy::Component::FetchFormForm < ApplyMate::Component::Base
  def initialize(form:, **)
    @form = form
  end
end
