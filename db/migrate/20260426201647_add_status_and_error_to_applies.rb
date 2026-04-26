# frozen_string_literal: true

class AddStatusAndErrorToApplies < ActiveRecord::Migration[8.1]
  def change
    add_column :applies, :status, :integer, default: 0, null: false
    add_column :applies, :error, :text
  end
end
