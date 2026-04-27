# frozen_string_literal: true

class SourceProfile::Operation::Edit < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.source_profiles.find(params[:id])
    authorize! model, :edit?

    if params[:source_profile].present?
      form_object = SourceProfile::FormObject::Create.new(params[:source_profile])
      form_object.sync_to model
    end
  end
end
