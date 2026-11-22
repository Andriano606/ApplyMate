# frozen_string_literal: true

# Inserts the given `{ host:, port:, protocol: }` candidates. Existing rows are left
# untouched (ON CONFLICT DO NOTHING) — they keep their created_at (Validate's ordering) and
# their per-source stats, so a known-bad proxy that reappears in the lists is not reset to
# a clean slate. Written in BATCH_SIZE slices so a large input never turns
# into one giant statement for Ruby to build and Postgres to parse.
#
# Model: the number of rows actually inserted (conflicts are not counted).
class Proxy::Operation::PersistProxies < ApplyMate::Operation::Base
  BATCH_SIZE = 5_000

  def perform!(proxies:, **)
    now = Time.current

    self.model = proxies.each_slice(BATCH_SIZE).sum do |slice|
      records = slice.map { |p| p.slice(:host, :port, :protocol).merge(created_at: now, updated_at: now) }
      Proxy.insert_all(records, unique_by: %i[host port protocol]).length
    end
  end
end
