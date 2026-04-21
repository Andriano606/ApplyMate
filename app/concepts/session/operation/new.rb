# frozen_string_literal: true

class Session::Operation::New < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    skip_authorize
  end
end
