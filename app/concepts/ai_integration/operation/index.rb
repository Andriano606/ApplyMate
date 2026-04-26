# frozen_string_literal: true

class AiIntegration::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = policy_scope(AiIntegration).paginate(page: params[:page])
    authorize! model, :index?
  end
end
