# frozen_string_literal: true

class RemovePendingStatusFromApplies < ActiveRecord::Migration[8.0]
  def up
    change_column_null :applies, :status, true
    change_column_default :applies, :status, from: 0, to: nil
    execute "UPDATE applies SET status = NULL WHERE status = 0"
  end

  def down
    execute "UPDATE applies SET status = 0 WHERE status IS NULL"
    change_column_default :applies, :status, from: nil, to: 0
    change_column_null :applies, :status, false
  end
end
