# frozen_string_literal: true

class AddPayloadToApplies < ActiveRecord::Migration[8.1]
  def change
    add_column :applies, :payload, :jsonb
  end
end
