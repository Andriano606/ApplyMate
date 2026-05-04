# frozen_string_literal: true

class Prompt::Operation::Edit < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.prompts.find(params[:id])
    authorize! model, :edit?
  end
end
