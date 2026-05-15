# frozen_string_literal: true

class Apply::Operation::Show < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    apply = policy_scope(Apply).includes(:vacancy, :user_profile, :ai_integration).find(params[:id])
    authorize! apply, :show?

    self.model = ApplyMate::Operation::Struct.new(apply:)
  end
end
