# frozen_string_literal: true

class AddApplybleToApplies < ActiveRecord::Migration[8.1]
  def change
    add_column :applies, :applyble, :boolean
  end
end
