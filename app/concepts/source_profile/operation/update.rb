# frozen_string_literal: true

class SourceProfile::Operation::Update < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.source_profiles.find(params[:id])
    authorize! model, :update?

    form = SourceProfile::FormObject::Create.new(params[:source_profile])
    parse_validate_sync(form, model)
    model.save!
    notice(I18n.t('source_profile.update.success'))
  end
end
