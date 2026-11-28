# frozen_string_literal: true

# The proxy pool moved to the separate ProxyMate service (ApplyMate::Client::ProxyMate);
# ApplyMate no longer collects, validates or scores proxies. The blocks keep it reversible.
class DropProxies < ActiveRecord::Migration[8.1]
  def change
    drop_table :proxy_source_stats do |t|
      t.references :proxy, null: false, foreign_key: true
      t.references :source, null: false, foreign_key: true
      t.integer :success_count, default: 0, null: false
      t.integer :fail_count, default: 0, null: false
      t.datetime :failed_at
      t.float :reliability, default: 1.0, null: false
      t.timestamps
      t.index [ :proxy_id, :source_id ], unique: true
      t.index [ :source_id, :failed_at ]
      t.index [ :source_id, :reliability ]
    end

    drop_table :proxies do |t|
      t.string :host, null: false
      t.integer :port, null: false
      t.string :protocol, default: 'http', null: false
      t.integer :fail_count, default: 0, null: false
      t.integer :success_count, default: 0, null: false
      t.float :reliability, default: 1.0, null: false
      t.datetime :failed_at
      t.datetime :last_used_at
      t.timestamps
      t.index [ :host, :port, :protocol ], unique: true
      t.index :failed_at
      t.index :last_used_at
      t.index :reliability
    end
  end
end
