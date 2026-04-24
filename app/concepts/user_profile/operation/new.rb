# frozen_string_literal: true

class UserProfile::Operation::New < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.user_profiles.build
    authorize! model, :new?
  end
end
