# frozen_string_literal: true

class Vacancy::Operation::Show < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy = Vacancy.includes(:source).find(params[:id])
    authorize! vacancy, :show?

    apply = current_user&.applies&.find_by(vacancy_id: vacancy.id)

    self.model = ApplyMate::Operation::Struct.new(vacancy:, apply:, expanded: params[:expanded].present?)
  end
end
