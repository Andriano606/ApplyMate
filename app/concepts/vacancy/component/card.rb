# frozen_string_literal: true

class Vacancy::Component::Card < ApplyMate::Component::Base
  def initialize(vacancy:)
    @vacancy = vacancy
  end

  private

  def description
    sanitized = ActionController::Base.helpers.strip_tags(@vacancy.description)
    truncate(sanitized, length: 150, separator: ' ')
  end
end
