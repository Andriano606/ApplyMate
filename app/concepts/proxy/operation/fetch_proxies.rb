# frozen_string_literal: true

class Proxy::Operation::FetchProxies < ApplyMate::Operation::Base
  include ApplyMate::Logging

  def perform!(**)
    inserted = 0
    persist  = ->(batch) { inserted += Proxy::Operation::PersistProxies.call(proxies: batch).model }

    candidates = Proxy::Operation::FetchCandidates.call(on_batch: persist).model

    log("Fetched #{candidates} candidates, inserted #{inserted} new proxies", color: :green)
    self.model = inserted
  end
end
