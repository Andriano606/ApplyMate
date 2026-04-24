# frozen_string_literal: true

class UserProfile::Operation::Edit < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.user_profiles.find(params[:id])
    authorize! model, :edit?
  end
end
