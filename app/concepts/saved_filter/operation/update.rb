# frozen_string_literal: true

class SavedFilter::Operation::Update < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.saved_filters.find(params[:id])
    authorize! model, :update?

    model.name = params.dig(:saved_filter, :name) if params.key?(:saved_filter)
    model.assign_attributes(state_attributes(params))
    reset_view_snapshot if model.vacancy_search_changed?
    model.save!
    current_user.update!(default_saved_filter: model) if current_user.default_saved_filter_id != model.id
    notice(I18n.t('saved_filter.update.success'))
  end

  private

  # The old snapshot describes the old state; the refresh right after the save
  # re-renders the results and records a fresh one
  def reset_view_snapshot
    model.last_seen_count = nil
    model.last_seen_max_vacancy_id = nil
  end

  # The modal nests the state under saved_filter; the "save into the current
  # preset" link saves straight away and sends it as plain query params.
  def state_attributes(params)
    source = params[:saved_filter].presence || params

    { include_tags: Array.wrap(source[:include_tags]),
      include_ops:  Array.wrap(source[:include_ops]),
      exclude_tags: Array.wrap(source[:exclude_tags]) }
  end
end
