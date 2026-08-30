# frozen_string_literal: true

class SavedFilter::Operation::New < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.saved_filters.build(
      include_tags: Array.wrap(params[:include_tags]),
      include_ops:  Array.wrap(params[:include_ops]),
      exclude_tags: Array.wrap(params[:exclude_tags])
    )
    authorize! model, :new?
  end
end
