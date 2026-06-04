# frozen_string_literal: true

class Admin::ApiToken::Operation::New < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    self.model = ApiToken.new
    authorize! model, :new?
  end
end
