# frozen_string_literal: true

class SourceProfile::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.source_profiles.build
    authorize! model, :create?

    form_object = SourceProfile::FormObject::Create.new(params[:source_profile])
    parse_validate_sync(form_object, model)
    model.save!
    notice(I18n.t('source_profile.create.success'))
  end
end
