# frozen_string_literal: true

class Proxy::Job::FetchProxies < ApplicationJob
  queue_as :default

  def perform
    Proxy::Operation::FetchProxies.call
  end
end
