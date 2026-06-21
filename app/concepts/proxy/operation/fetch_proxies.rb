# frozen_string_literal: true

class Proxy::Operation::FetchProxies < ApplyMate::Operation::Base
  include ApplyMate::Logging

  def perform!(**)
    candidates = Proxy::Operation::FetchCandidates.call.model
    persisted  = Proxy::Operation::PersistProxies.call(proxies: candidates).model

    log("Fetched #{candidates.size} candidates, persisted #{persisted} proxies", color: :green)
    self.model = persisted
  end
end
