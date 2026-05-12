# frozen_string_literal: true

class Admin::ProxiesController < Admin::BaseController
  def index
    endpoint Admin::Proxy::Operation::Index, Admin::Proxy::Component::Index
  end

  def show
    endpoint Admin::Proxy::Operation::Show, Admin::Proxy::Component::ShowModal
  end
end
