# frozen_string_literal: true

class Admin::DashboardController < Admin::BaseController
  def index
    endpoint Admin::Dashboard::Operation::Index, Admin::Dashboard::Component::Index
  end
end
