# frozen_string_literal: true

class RenameRecentSuccessCountToSuccessCountOnProxies < ActiveRecord::Migration[8.0]
  def change
    rename_column :proxies, :recent_success_count, :success_count
  end
end
