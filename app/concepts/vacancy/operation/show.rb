# frozen_string_literal: true

class Vacancy::Operation::Show < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy = Vacancy.includes(:source, :vacancy_cvs).find(params[:id])
    authorize! vacancy, :show?

    self.model = ApplyMate::Operation::Struct.new(vacancy:)
  end
end
