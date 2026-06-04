# frozen_string_literal: true

class Admin::ApiToken::Operation::Destroy < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    self.model = ApiToken.find(params[:id])
    authorize! model, :destroy?
    model.destroy!
    notice(I18n.t('admin.api_token.destroy.success'))
  end
end
