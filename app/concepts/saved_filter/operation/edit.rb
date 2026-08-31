# frozen_string_literal: true

class SavedFilter::Operation::Edit < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.saved_filters.find(params[:id])
    authorize! model, :edit?

    # Opened from the search bar with a modified state: show that state in the
    # form so saving overwrites the preset with what the user currently sees.
    return unless params.key?(:include_tags) || params.key?(:exclude_tags)

    model.include_tags = Array.wrap(params[:include_tags])
    model.include_ops  = Array.wrap(params[:include_ops])
    model.exclude_tags = Array.wrap(params[:exclude_tags])
  end
end
