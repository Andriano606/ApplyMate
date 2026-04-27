# frozen_string_literal: true

class Apply::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.applies.build
    authorize! model, :create?
    form_object = Apply::FormObject::Create.new(params[:apply])
    parse_validate_sync(form_object, model)
    ApplicationRecord.transaction do
      model.save!
      current_user.update!(
        default_profile_id: model.user_profile_id,
        default_ai_integration_id: model.ai_integration_id,
        default_source_profile_id: model.source_profile_id
      )
    end

    Apply::Job::Apply.perform_later(model.id)
    notice(I18n.t('apply.create.success'))
  end
end
