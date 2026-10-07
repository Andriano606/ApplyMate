# frozen_string_literal: true

class AddApplyEngineFieldsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :daily_apply_limit, :integer, null: false, default: 30
    add_column :users, :applies_changed_at, :datetime # cache key of the navbar attention counter
  end
end
