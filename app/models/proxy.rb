# frozen_string_literal: true

class Proxy < ApplicationRecord
  scope :available, -> { where(active: true) }

  def url
    "#{protocol}://#{host}:#{port}"
  end

  def mark_used!
    update_column(:last_used_at, Time.current)
  end

  def mark_failed!
    update_columns(active: false, failed_at: Time.current)
  end
end
