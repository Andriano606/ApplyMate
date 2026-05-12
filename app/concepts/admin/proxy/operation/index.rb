# frozen_string_literal: true

class Admin::Proxy::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, **)
    authorize! Proxy, :index?
    self.model = Proxy.order(fail_count: :asc, created_at: :desc).paginate(page: params[:page])
  end
end
