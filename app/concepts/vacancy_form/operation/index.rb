# frozen_string_literal: true

class VacancyForm::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy       = Vacancy.find(params[:vacancy_id])
    vacancy_forms = policy_scope(VacancyForm).where(vacancy:).order(:created_at)
    authorize! VacancyForm.new, :index?
    self.model = ApplyMate::Operation::Struct.new(vacancy:, vacancy_forms:)
  end
end
