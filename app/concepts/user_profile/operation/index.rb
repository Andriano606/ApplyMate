# frozen_string_literal: true

class UserProfile::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    authorize! UserProfile.new, :index?
    self.model = policy_scope(UserProfile).order(:created_at)
  end
end
