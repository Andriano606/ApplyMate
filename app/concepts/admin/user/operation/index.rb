# frozen_string_literal: true

class Admin::User::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    authorize! User, :index?
    self.model = policy_scope(User).order(:name).paginate(page: params[:page])
  end
end
