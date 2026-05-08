# frozen_string_literal: true

class CreateProxies < ActiveRecord::Migration[8.1]
  def change
    create_table :proxies do |t|
      t.string   :host,     null: false
      t.integer  :port,     null: false
      t.string   :protocol, null: false, default: 'http'
      t.boolean  :active,   null: false, default: true
      t.datetime :failed_at
      t.datetime :last_used_at

      t.timestamps
    end

    add_index :proxies, [ :host, :port ], unique: true
    add_index :proxies, :active
  end
end
