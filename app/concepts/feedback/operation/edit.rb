# frozen_string_literal: true

class Feedback::Operation::Edit < ApplyMate::Operation::Base
  def perform!(params:, **)
    self.model = Feedback.find(params[:id])
    authorize! model, :edit?
  end
end
