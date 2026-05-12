# frozen_string_literal: true

class Admin::Proxy::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, **)
    authorize! Proxy, :index?
    self.model = Proxy.by_reliability.paginate(page: params[:page])
  end
end
