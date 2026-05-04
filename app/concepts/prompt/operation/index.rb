# frozen_string_literal: true

class Prompt::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = policy_scope(Prompt).order(prompt_type: :asc).paginate(page: params[:page])
    authorize! model, :index?
  end
end
