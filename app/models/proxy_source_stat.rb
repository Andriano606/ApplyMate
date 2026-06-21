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
end
