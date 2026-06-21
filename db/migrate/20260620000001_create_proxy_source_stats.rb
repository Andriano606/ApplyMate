# frozen_string_literal: true

class CreateProxySourceStats < ActiveRecord::Migration[8.1]
  def change
    create_table :proxy_source_stats do |t|
      t.references :proxy,  null: false, foreign_key: true
      t.references :source, null: false, foreign_key: true
      t.integer  :success_count, default: 0, null: false
      t.integer  :fail_count,    default: 0, null: false
      t.datetime :failed_at
      t.float    :reliability,   default: 1.0, null: false
      t.timestamps
    end

    add_index :proxy_source_stats, %i[proxy_id source_id], unique: true
    # Supports per-source candidate selection / ordering in SyncVacancies.
    add_index :proxy_source_stats, %i[source_id reliability]
    add_index :proxy_source_stats, %i[source_id failed_at]
  end
end
