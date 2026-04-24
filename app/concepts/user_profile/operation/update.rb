# frozen_string_literal: true

class UserProfile::Operation::Update < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.user_profiles.find(params[:id])
    authorize! model, :update?
    model.assign_attributes(params[:user_profile].permit(:name, :cv))
    model.save!
    notice(I18n.t('user_profile.update.success'))
  end
end
