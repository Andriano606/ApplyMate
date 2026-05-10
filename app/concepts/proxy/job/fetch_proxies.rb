# frozen_string_literal: true

class Proxy::Job::FetchProxies < ApplicationJob
  queue_as :default

  def perform
    candidates = Proxy::Operation::FetchCandidates.call.model
    valid      = Proxy::Operation::ValidateCandidates.call(candidates: candidates).model
    Proxy::Operation::PersistProxies.call(proxies: valid)
  end
end
