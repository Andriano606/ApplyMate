# frozen_string_literal: true

class UserProfile::Operation::Destroy < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.user_profiles.find(params[:id])
    authorize! model, :destroy?
    model.destroy!
    notice(I18n.t('user_profile.destroy.success'))
  end
end
