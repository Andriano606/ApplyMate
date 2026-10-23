# frozen_string_literal: true

# Deletes proxies that have not proven themselves for any source within PRUNE_AFTER of
# being first inserted: either still untested (Validate picks the newest first, so old
# untested rows would otherwise wait forever) or tested and failing everywhere. Proxies
# working for at least one source are kept.
#
# This is the `proxies` table's pruning story: FetchProxies adds up to
# FetchCandidates::MAX_CANDIDATES rows a night. A pruned proxy that still appears in the
# public lists is re-inserted by a later fetch with a fresh created_at, and so gets
# probed again.
#
# Model: the number of proxies deleted.
class Proxy::Operation::PruneProxies < ApplyMate::Operation::Base
  include ApplyMate::Logging

  PRUNE_AFTER = 3.days
  BATCH_SIZE  = 5_000
  NOT_WORKING = 'NOT EXISTS (SELECT 1 FROM proxy_source_stats s WHERE s.proxy_id = proxies.id AND s.success_count > 0)'

  def perform!(older_than: PRUNE_AFTER.ago, **)
    deleted = 0
    # Batches walk the primary key; the anti-join rides index_proxy_source_stats_on_proxy_id.
    Proxy.where(created_at: ...older_than).where(NOT_WORKING).in_batches(of: BATCH_SIZE) do |batch|
      deleted += delete_batch(batch.pluck(:id))
    end

    log("Pruned #{deleted} proxies not working for any source") if deleted.positive?
    self.model = deleted
  end

  private

  # Proxy::Job::Validate (every 5 minutes) may be recording a first result for one of these
  # proxies right now. Its stats insert holds a KEY SHARE lock on the proxy row, so
  # FOR UPDATE SKIP LOCKED leaves that proxy alone, and NOT_WORKING is re-checked here so a
  # success committed since the batch was read keeps the proxy. A Validate insert that comes
  # after this lock waits for the commit and then fails its FK — that one Validate run loses
  # its results; the next run (5 minutes later) is unaffected.
  def delete_batch(ids)
    Proxy.transaction do
      locked = Proxy.where(id: ids).where(NOT_WORKING).lock('FOR UPDATE SKIP LOCKED').pluck(:id)
      ProxySourceStat.where(proxy_id: locked).delete_all
      Proxy.where(id: locked).delete_all
    end
  end
end
