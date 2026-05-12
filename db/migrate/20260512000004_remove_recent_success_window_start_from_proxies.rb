# frozen_string_literal: true

class RemoveRecentSuccessWindowStartFromProxies < ActiveRecord::Migration[8.0]
  def change
    remove_column :proxies, :recent_success_window_start, :datetime
  end
end
