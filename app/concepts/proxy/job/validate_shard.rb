# frozen_string_literal: true

class Proxy::Job::ValidateShard < ApplicationJob
  queue_as :default

  def perform(cache_key)
    candidates = Rails.cache.read(cache_key)&.map(&:symbolize_keys)
    return if candidates.blank?

    valid = Proxy::Operation::ValidateCandidates.call(candidates: candidates).model
    Proxy::Operation::PersistProxies.call(proxies: valid)
  ensure
    Rails.cache.delete(cache_key)
  end
end
