# frozen_string_literal: true

class Apply::Operation::Destroy < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = policy_scope(Apply).find(params[:id])
    authorize! model, :destroy?
    model.destroy!
    notice(I18n.t('apply.destroy.success'))
  end
end
