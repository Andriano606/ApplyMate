# frozen_string_literal: true

class Mcp::Operation::GetMyFeedback < ApplyMate::Operation::Base
  def perform!(current_user:, **)
    authorize! Feedback, :index?

    self.model = Feedback.find_by(user: current_user)
  end
end
