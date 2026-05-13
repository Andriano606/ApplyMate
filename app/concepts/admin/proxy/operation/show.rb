# frozen_string_literal: true

class Admin::Proxy::Operation::Show < ApplyMate::Operation::Base
  def perform!(params:, **)
    proxy = Proxy.find(params[:id])
    authorize! proxy, :show?

    self.model = ApplyMate::Operation::Struct.new(
      proxy:   proxy,
      sources: Source.all
    )
  end
end
