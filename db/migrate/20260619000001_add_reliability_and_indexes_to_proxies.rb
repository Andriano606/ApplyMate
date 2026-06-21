# frozen_string_literal: true

class AddReliabilityAndIndexesToProxies < ActiveRecord::Migration[8.1]
  def up
    # Stored success ratio so SyncVacancies' proxy refill can ORDER BY an indexed
    # column instead of recomputing COALESCE(success/(success+fail)) over ~1M rows
    # on every refill. Untested proxies default to 1.0 (optimistic — tried early,
    # dropped fast if bad).
    add_column :proxies, :reliability, :float, default: 1.0, null: false

    execute <<~SQL.squish
      UPDATE proxies
      SET reliability = success_count::float / (success_count + fail_count)
      WHERE success_count + fail_count > 0
    SQL

    add_index :proxies, :reliability
    add_index :proxies, :failed_at
    add_index :proxies, :last_used_at
  end

  def down
    remove_index :proxies, :last_used_at
    remove_index :proxies, :failed_at
    remove_index :proxies, :reliability
    remove_column :proxies, :reliability
  end
end
