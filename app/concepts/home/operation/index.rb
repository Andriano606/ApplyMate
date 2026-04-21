# frozen_string_literal: true

class Home::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    skip_authorize
  end
end
