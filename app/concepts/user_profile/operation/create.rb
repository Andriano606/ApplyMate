# frozen_string_literal: true

class UserProfile::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.user_profiles.build
    authorize! model, :create?
    model.assign_attributes(params[:user_profile].permit(:name, :cv))
    model.save!
    UserProfile::Job::ExtractFacts.perform_later(model.id) if model.saved_change_to_cv?
    notice(I18n.t('user_profile.create.success'))
  end
end
