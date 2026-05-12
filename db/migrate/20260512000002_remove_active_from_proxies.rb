# frozen_string_literal: true

class RemoveActiveFromProxies < ActiveRecord::Migration[8.0]
  def change
    remove_index :proxies, :active
    remove_column :proxies, :active, :boolean, default: true, null: false
  end
end
