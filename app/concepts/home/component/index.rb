# frozen_string_literal: true

class Home::Component::Index < ApplyMate::Component::Base
  def initialize(vacancies:, **)
    @vacancies = vacancies
  end
end
