# frozen_string_literal: true

class Proxy < ApplicationRecord
  MAX_FAIL_RATIO = 0.45
  MAX_FAIL_COUNTER = 3

  # Per-source reliability lives in proxy_source_stats (a proxy can work for one
  # site and be blocked on another). The columns on `proxies` itself are a legacy
  # global aggregate, no longer written by the sync/validation pipeline.
  has_many :proxy_source_stats, dependent: :delete_all

  # Ordered by the stored `reliability` column (indexed) so large `ready_for_use`
  # scans (SyncVacancies refill over ~1M rows) avoid recomputing the success ratio
  # and full-sorting. `reliability` is maintained on every success/fail write.
  scope :by_reliability, -> {
    order(reliability: :desc, success_count: :desc, created_at: :asc)
  }

  scope :ready_for_use, -> {
    where('last_used_at IS NULL OR last_used_at < ?', 5.seconds.ago)
      .where('failed_at IS NULL OR failed_at < ?', 1.minute.ago)
      .by_reliability
  }

  def url
    "#{protocol}://#{host}:#{port}"
  end

  def mark_used!
    update_column(:last_used_at, Time.current)
  end

  def increment_fail!
    new_fail_count = fail_count + 1
    total = new_fail_count + success_count
    if (new_fail_count.to_f / total >= MAX_FAIL_RATIO) && (new_fail_count >= MAX_FAIL_COUNTER)
      destroy
    else
      update_columns(fail_count: new_fail_count, failed_at: Time.current,
                     reliability: self.class.reliability_for(success_count, new_fail_count))
    end
  end

  def increment_succeeded!(by = 1)
    new_success = success_count + by
    update_columns(success_count: new_success,
                   reliability: self.class.reliability_for(new_success, fail_count))
  end

  # Success ratio; 1.0 when untested (optimistic — tried early, dropped fast if bad).
  def self.reliability_for(success, fail)
    total = success + fail
    total.zero? ? 1.0 : success.to_f / total
  end
end
