# frozen_string_literal: true

class SavedFilter::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.saved_filters.build(
      name:         params.dig(:saved_filter, :name),
      include_tags: Array.wrap(params.dig(:saved_filter, :include_tags)),
      include_ops:  Array.wrap(params.dig(:saved_filter, :include_ops)),
      exclude_tags: Array.wrap(params.dig(:saved_filter, :exclude_tags))
    )
    authorize! model, :create?
    model.save!
    current_user.update!(default_saved_filter: model)
    notice(I18n.t('saved_filter.create.success'))
  end
end
