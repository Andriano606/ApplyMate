# frozen_string_literal: true

# The daily apply limit was removed by the owner (2026-10-09): the number of applications is not capped.
class RemoveDailyApplyLimitFromUsers < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :daily_apply_limit, :integer, null: false, default: 30
  end
end
