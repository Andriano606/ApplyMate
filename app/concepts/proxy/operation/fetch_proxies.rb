# frozen_string_literal: true

class Proxy::Operation::FetchProxies < ApplyMate::Operation::Base
  include ApplyMate::Logging

  # Fetch first, prune after: the night's intake is persisted before housekeeping runs, so a
  # failing prune surfaces as a failed job without costing the fetch. Rows inserted just now
  # are far younger than PruneProxies::PRUNE_AFTER and are never touched by it.
  def perform!(**)
    inserted = 0
    persist  = ->(batch) { inserted += Proxy::Operation::PersistProxies.call(proxies: batch).model }

    candidates = Proxy::Operation::FetchCandidates.call(on_batch: persist).model
    pruned     = Proxy::Operation::PruneProxies.call.model

    log("Fetched #{candidates} candidates, inserted #{inserted} new proxies, pruned #{pruned}", color: :green)
    self.model = inserted
  end
end
