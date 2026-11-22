# frozen_string_literal: true

class Proxy::Operation::FetchProxies < ApplyMate::Operation::Base
  include ApplyMate::Logging

  def perform!(**)
    inserted = 0
    persist  = ->(batch) { inserted += Proxy::Operation::PersistProxies.call(proxies: batch).model }

    started    = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    candidates = Proxy::Operation::FetchCandidates.call(on_batch: persist).model

    log(event: 'proxy_fetch_finished', candidates: candidates, inserted: inserted,
        duration_s: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3))
    self.model = inserted
  end
end
