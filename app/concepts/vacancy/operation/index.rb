# frozen_string_literal: true

class Vacancy::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    authorize! Vacancy.new, :index?
    self.model = Vacancy.order(:created_at).paginate(page: params[:page])
  end
end
