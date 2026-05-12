# frozen_string_literal: true

class Proxy < ApplicationRecord
  MAX_FAIL_COUNT = 20

  scope :ready_for_use, -> {
    where('last_used_at IS NULL OR last_used_at < ?', 3.seconds.ago)
      .where('failed_at IS NULL OR failed_at < ?', 1.minute.ago)
      .order('last_used_at ASC NULLS FIRST')
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
      update_columns(fail_count: fail_count + 1, failed_at: Time.current)
    end
  end

  def reset_fail!
    update_columns(fail_count: 0, failed_at: nil) if fail_count > 0
  end
end
