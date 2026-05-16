# frozen_string_literal: true

class Admin::JobStatsController < Admin::BaseController
  def index
    endpoint Admin::JobStats::Operation::Index, Admin::JobStats::Component::Index
  end
end
