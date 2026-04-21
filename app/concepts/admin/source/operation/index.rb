# frozen_string_literal: true

class Admin::Source::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    authorize! Source, :index?
    self.model = Source.order(:created_at).paginate(page: params[:page])
  end
end
