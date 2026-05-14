# frozen_string_literal: true

class Proxy < ApplicationRecord
  MAX_FAIL_RATIO = 0.75
  MAX_FAIL_COUNTER = 3

  scope :by_reliability, -> {
    order(
      Arel.sql(<<~SQL)
      (fail_count + success_count = 0) ASC,
      COALESCE(success_count::float / NULLIF(fail_count + success_count, 0), 1.0) DESC
    SQL
    )
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
      update_columns(fail_count: new_fail_count, failed_at: Time.current)
    end
  end

  def increment_succeeded!
    update_columns(success_count: success_count + 1)
  end
end
