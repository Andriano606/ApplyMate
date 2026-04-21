# frozen_string_literal: true

class Admin::Source::Operation::Destroy < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    self.model = Source.find(params[:id])
    authorize! model, :destroy?
    model.destroy!
    notice(I18n.t('admin.source.destroy.success'))
  end
end
