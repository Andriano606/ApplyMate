class HiddenVacancy::Operation::Destroy < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy = Vacancy.find(params[:vacancy_id])
    authorize! HiddenVacancy.new(user: current_user, vacancy:), :destroy?

    self.model = current_user.hidden_vacancies.find_by!(vacancy:)
    model.destroy!
  end
end
