# frozen_string_literal: true

# An apply has no page of its own: AppliesController#show redirects to the apply card on the vacancy page.
class Apply::Operation::Show < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = policy_scope(Apply).includes(:vacancy).find(params[:id])
    authorize! model, :show?
  end
end
