# frozen_string_literal: true

class Vacancy::Component::GenerateCvForm < ApplyMate::Component::Base
  def initialize(form:, **)
    @form = form
  end
end
