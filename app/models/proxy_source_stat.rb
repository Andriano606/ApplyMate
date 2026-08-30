# frozen_string_literal: true

# Per-(proxy, source) reliability stats. A proxy that works for one site is often
# blocked on another (e.g. Dou's anti-scraping), so a single global success count is
# misleading — each source tracks its own success/fail/reliability here.
class ProxySourceStat < ApplicationRecord
  belongs_to :proxy
  belongs_to :source

  FAIL_COOLDOWN = 1.minute

  # Usable for this source right now: not in post-failure cooldown. Best-first.
  scope :ready_for_use, -> {
    where('failed_at IS NULL OR failed_at < ?', FAIL_COOLDOWN.ago).by_reliability
  }

  scope :by_reliability, -> {
    order(reliability: :desc, success_count: :desc, created_at: :asc)
  }

  scope :working, -> { where('success_count > 0') }

  # Success ratio; 1.0 when untested (optimistic — tried early, dropped fast if bad).
  def self.reliability_for(success, fail)
    total = success + fail
    total.zero? ? 1.0 : success.to_f / total
  end

  # Applies buffered per-(proxy, source) deltas in a single statement. Rows carry
  # *increments*, not absolute totals, and the counters are summed SQL-side.
  #
  # Two writers touch these rows concurrently — SyncVacancies' pool flush and
  # Proxy::Operation::Validate — and both used to SELECT the current totals and
  # upsert absolute values. Between the SELECT and the write the other writer's
  # increments were lost, resetting a proven proxy's reputation to the caller's
  # own delta. Incrementing in SQL makes the write commutative instead.
  def self.apply_deltas!(rows)
    return if rows.empty?

    upsert_all(
      rows,
      unique_by: %i[proxy_id source_id],
      on_duplicate: Arel.sql(<<~SQL.squish),
        success_count = proxy_source_stats.success_count + EXCLUDED.success_count,
        fail_count    = proxy_source_stats.fail_count + EXCLUDED.fail_count,
        failed_at     = COALESCE(EXCLUDED.failed_at, proxy_source_stats.failed_at),
        reliability   = (proxy_source_stats.success_count + EXCLUDED.success_count)::float
                        / GREATEST(proxy_source_stats.success_count + EXCLUDED.success_count
                                   + proxy_source_stats.fail_count + EXCLUDED.fail_count, 1),
        updated_at    = now()
      SQL
      record_timestamps: true
    )
  end
end
