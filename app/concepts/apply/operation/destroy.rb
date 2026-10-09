# frozen_string_literal: true

class Apply::Operation::Destroy < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = policy_scope(Apply).includes(:vacancy).find(params[:id])
    authorize! model, :destroy?
    model.destroy!
    # After the delete: a render between a touch and the delete would cache the old count under the new key.
    model.touch_user_applies_changed_at!
    # Badge and action box fall back to the remaining latest apply; panel, CV list and question suggestions
    # drop this apply.
    Apply::TurboHandler::StatusUpdate.refresh(model.vacancy, current_user)
    VacancyCv::TurboHandler::Index.broadcast(model.vacancy, current_user)
    VacancyQuestion::TurboHandler::Index.broadcast(model.vacancy, current_user)
    notice(I18n.t('apply.destroy.success'))
  end
end
