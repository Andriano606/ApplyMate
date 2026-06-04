# frozen_string_literal: true

class Admin::ApiToken::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    self.model = ApiToken.new
    authorize! model, :create?
    model.assign_attributes(params[:api_token].permit(:user_id, :name))
    model.save!
    notice(I18n.t('admin.api_token.create.success'))
  end
end
