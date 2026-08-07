# frozen_string_literal: true

class VacancyQuestion::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy           = Vacancy.find(params[:vacancy_id])
    vacancy_questions = policy_scope(VacancyQuestion).where(vacancy:).order(:created_at)
    authorize! VacancyQuestion.new, :index?
    self.model = ApplyMate::Operation::Struct.new(vacancy:, vacancy_questions:)
  end
end
