# frozen_string_literal: true

# MCP `set_vacancy_hidden`: hide a vacancy for the user (as the web "hide" button
# does) or restore it. Idempotent — hiding a hidden one or restoring a visible
# one is a no-op.
class Mcp::Operation::SetVacancyHidden < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy = Vacancy.find_by_hashid(params[:id].to_s)
    return not_found(params[:id]) if vacancy.nil?

    hidden = params[:hidden] != false
    authorize! HiddenVacancy.new(user: current_user, vacancy:), hidden ? :create? : :destroy?

    if hidden
      run_operation(HiddenVacancy::Operation::Create, { params: { vacancy_id: vacancy.id }, current_user: })
    elsif current_user.hidden_vacancies.exists?(vacancy:)
      run_operation(HiddenVacancy::Operation::Destroy, { params: { vacancy_id: vacancy.id }, current_user: })
    end

    self.model = ApplyMate::Operation::Struct.new(vacancy:, hidden:)
  end

  private

  def not_found(id)
    skip_authorize
    add_error(:not_found, I18n.t('mcp.errors.unknown_vacancy', id:))
  end
end
