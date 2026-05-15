# frozen_string_literal: true

class Vacancy::Component::InfoCard < ApplyMate::Component::Base
  def initialize(vacancy:)
    @vacancy = vacancy
  end
end
