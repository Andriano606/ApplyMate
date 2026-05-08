# frozen_string_literal: true

class AddApplyTypeToApplies < ActiveRecord::Migration[8.0]
  def change
    add_column :applies, :apply_type, :integer, default: 0, null: false
  end
end
