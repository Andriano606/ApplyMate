# frozen_string_literal: true

class AddRecentSuccessToProxies < ActiveRecord::Migration[8.0]
  def change
    add_column :proxies, :recent_success_count, :integer, default: 0, null: false
    add_column :proxies, :recent_success_window_start, :datetime
  end
end
