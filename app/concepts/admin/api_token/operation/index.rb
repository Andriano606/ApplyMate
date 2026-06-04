# frozen_string_literal: true

class Admin::ApiToken::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    authorize! ApiToken, :index?
    self.model = ApiToken.includes(:user).order(created_at: :desc).paginate(page: params[:page])
  end
end
