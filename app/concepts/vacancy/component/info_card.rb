class Vacancy::Component::InfoCard < ApplyMate::Component::Base
  def initialize(vacancy:)
    @vacancy = vacancy
  end

  private

  def description_html
    @description_html ||= vacancy_description_html(@vacancy)
  end
end
