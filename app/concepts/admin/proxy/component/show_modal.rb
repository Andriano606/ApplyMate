# frozen_string_literal: true

class Admin::Proxy::Component::ShowModal < ApplyMate::Component::Base
  available_for :admin

  def initialize(proxy:, sources:, **)
    @proxy   = proxy
    @sources = sources
  end
end
