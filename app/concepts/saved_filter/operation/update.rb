# frozen_string_literal: true

class SavedFilter::Operation::Update < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.saved_filters.find(params[:id])
    authorize! model, :update?

    model.name = params.dig(:saved_filter, :name) if params.key?(:saved_filter)
    model.assign_attributes(state_attributes(params))
    model.save!
    current_user.update!(default_saved_filter: model) if current_user.default_saved_filter_id != model.id
    notice(I18n.t('saved_filter.update.success'))
  end

  private

  # The modal nests the state under saved_filter; the "save into the current
  # preset" link saves straight away and sends it as plain query params.
  def state_attributes(params)
    source = params[:saved_filter].presence || params

    { include_tags: Array.wrap(source[:include_tags]),
      include_ops:  Array.wrap(source[:include_ops]),
      exclude_tags: Array.wrap(source[:exclude_tags]) }
  end
end
