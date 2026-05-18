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
    cache_keys = candidates.each_slice(shard_size).each_with_index.map do |shard, i|
      key = "proxy_shard_#{job_id}_#{i}"
      Rails.cache.write(key, shard, expires_in: (shard_count * 3).hours)
      key
    end
    Proxy::Job::ValidateShard.perform_later(cache_keys.first, cache_keys.drop(1))
  end
end
