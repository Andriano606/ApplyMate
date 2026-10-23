# frozen_string_literal: true

class Proxy::Job::FetchProxies < ApplicationJob
  queue_as :default

  # Daily; a bounded run takes minutes (the first prune of a ~1.7M-row table longer).
  # Hold the semaphore well past that so a manual enqueue cannot overlap the nightly run.
  limits_concurrency to: 1, key: 'proxy_fetch', duration: 1.hour

  def perform
    Proxy::Operation::FetchProxies.call
  end
end
