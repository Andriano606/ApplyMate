# frozen_string_literal: true

class Apply::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = policy_scope(Apply).includes(:vacancy, :user_profile, :ai_integration)
                                    .order(created_at: :desc)
                                    .paginate(page: params[:page])
    authorize! model, :index?
  end
end
