# frozen_string_literal: true

class Admin::Source::Operation::Edit < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    self.model = Source.find(params[:id])
    authorize! model, :edit?
  end
end
