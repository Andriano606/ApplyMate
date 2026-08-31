# frozen_string_literal: true

class SavedFilter::Operation::Update < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.saved_filters.find(params[:id])
    authorize! model, :update?

    model.assign_attributes(
      name:         params.dig(:saved_filter, :name),
      include_tags: Array.wrap(params.dig(:saved_filter, :include_tags)),
      include_ops:  Array.wrap(params.dig(:saved_filter, :include_ops)),
      exclude_tags: Array.wrap(params.dig(:saved_filter, :exclude_tags))
    )
    model.save!
    current_user.update!(default_saved_filter: model) if current_user.default_saved_filter_id != model.id
    notice(I18n.t('saved_filter.update.success'))
  end
end
