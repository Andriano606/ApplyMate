# frozen_string_literal: true

class Feedback::Operation::New < ApplyMate::Operation::Base
  def perform!(current_user:, **)
    self.model = Feedback.new(user: current_user)
    authorize! model, :new?
  end
end
