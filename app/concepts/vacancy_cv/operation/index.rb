# frozen_string_literal: true

class VacancyCv::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy     = Vacancy.find(params[:vacancy_id])
    vacancy_cvs = policy_scope(VacancyCv).where(vacancy:).order(:created_at)
    authorize! VacancyCv.new, :index?
    self.model = ApplyMate::Operation::Struct.new(vacancy:, vacancy_cvs:)
  end
end
