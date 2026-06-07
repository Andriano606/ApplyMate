# frozen_string_literal: true

class Proxy::Operation::PersistProxies < ApplyMate::Operation::Base
  include ApplyMate::Logging

  def perform!(proxies:, **)
    if proxies.empty?
      self.model = 0
      return
    end

    now     = Time.current
    records = proxies.uniq { |p| [ p[:host], p[:port], p[:protocol] ] }
                     .map { |p| p.merge(created_at: now, updated_at: now) }

    Proxy.insert_all(records, unique_by: %i[host port protocol])
    log("Persisted #{records.size} proxies", color: :green)
    self.model = records.size
  end
end
