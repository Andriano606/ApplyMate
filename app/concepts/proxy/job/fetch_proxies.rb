# frozen_string_literal: true

class Proxy::Job::FetchProxies < ApplicationJob
  queue_as :default

  def perform
    shard_count = Integer(ENV.fetch('FETCH_PROXIES_SHARD_COUNT', '1'))
    candidates  = Proxy::Operation::FetchCandidates.call.model

    if shard_count <= 1
      valid = Proxy::Operation::ValidateCandidates.call(candidates: candidates).model
      Proxy::Operation::PersistProxies.call(proxies: valid)
      return
    end

    shard_size = (candidates.size / shard_count.to_f).ceil
    candidates.each_slice(shard_size).each_with_index do |shard, i|
      cache_key = "proxy_shard_#{job_id}_#{i}"
      Rails.cache.write(cache_key, shard, expires_in: 4.hours)
      Proxy::Job::ValidateShard.perform_later(cache_key)
    end
  end
end
