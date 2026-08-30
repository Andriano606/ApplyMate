# frozen_string_literal: true

class SavedFilter::Operation::Destroy < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.saved_filters.find(params[:id])
    authorize! model, :destroy?
    model.destroy!
    notice(I18n.t('saved_filter.destroy.success'))
  end
end
