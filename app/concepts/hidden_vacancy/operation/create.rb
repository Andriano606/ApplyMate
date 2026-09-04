class HiddenVacancy::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy = Vacancy.find(params[:vacancy_id])
    authorize! HiddenVacancy.new(user: current_user, vacancy:), :create?

    self.model = current_user.hidden_vacancies.create_or_find_by!(vacancy:)
  end
end
