# frozen_string_literal: true

class SourceProfile::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = policy_scope(SourceProfile).includes(:source)
                                            .order(created_at: :desc)
                                            .paginate(page: params[:page])
    authorize! model, :index?
  end
end
