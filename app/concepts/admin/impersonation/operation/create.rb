# frozen_string_literal: true

class Admin::Impersonation::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    skip_authorize
    self.model = User.find(params[:user_id])
  end
end
