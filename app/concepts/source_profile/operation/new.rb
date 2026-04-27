# frozen_string_literal: true

class SourceProfile::Operation::New < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.source_profiles.build

    if params[:source_profile].present?
      form_object = SourceProfile::FormObject::Create.new(params[:source_profile])
      form_object.auth_method ||= SourceProfile.auth_methods.keys.first
      form_object.sync_to model
    end

    authorize! model, :new?
  end
end
