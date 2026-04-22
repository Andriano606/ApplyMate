# frozen_string_literal: true

class Admin::Source::Operation::Update < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    self.model = Source.find(params[:id])
    authorize! model, :update?
    model.assign_attributes(params[:source].permit!)
    model.save!
    notice(I18n.t('admin.source.update.success'))
  end
end
