# frozen_string_literal: true

class Proxy < ApplicationRecord
  MAX_FAIL_COUNT = 20

  RECENT_SUCCESS_WINDOW = 5.minutes

  scope :ready_for_use, -> {
    where('last_used_at IS NULL OR last_used_at < ?', 3.seconds.ago)
      .where('failed_at IS NULL OR failed_at < ?', 1.minute.ago)
      .order(Arel.sql("CASE WHEN recent_success_window_start > NOW() - interval '5 minutes' THEN recent_success_count ELSE 0 END DESC, last_used_at ASC NULLS FIRST"))
  }

  def url
    "#{protocol}://#{host}:#{port}"
  end

  def mark_used!
    update_column(:last_used_at, Time.current)
  end

  def increment_fail!
    if fail_count + 1 >= MAX_FAIL_COUNT
      destroy
    else
      update_columns(fail_count: fail_count + 1, failed_at: Time.current,
                     recent_success_count: 0, recent_success_window_start: nil)
    end
  end

  def increment_succeeded!
    now       = Time.current
    in_window = recent_success_window_start.present? && (now - recent_success_window_start) < RECENT_SUCCESS_WINDOW
    cols = {
      recent_success_count:        in_window ? recent_success_count + 1 : 1,
      recent_success_window_start: in_window ? recent_success_window_start : now
    }
    cols[:fail_count] = 0
    cols[:failed_at]  = nil
    update_columns(cols)
  end
end
