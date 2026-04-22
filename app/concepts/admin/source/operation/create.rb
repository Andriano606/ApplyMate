# frozen_string_literal: true

class Admin::Source::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    self.model = Source.new
    authorize! model, :create?
    model.assign_attributes(params[:source].permit!)
    model.save!
    notice(I18n.t('admin.source.create.success'))
  end
end
