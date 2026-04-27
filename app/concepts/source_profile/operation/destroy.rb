# frozen_string_literal: true

class SourceProfile::Operation::Destroy < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.source_profiles.find(params[:id])
    authorize! model, :destroy?
    model.destroy!
    notice(I18n.t('source_profile.destroy.success'))
  end
end
