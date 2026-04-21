# frozen_string_literal: true

class Admin::Source::Operation::New < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    self.model = Source.new
    authorize! model, :new?
  end
end
