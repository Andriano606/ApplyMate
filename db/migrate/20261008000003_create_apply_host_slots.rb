# frozen_string_literal: true

class CreateApplyHostSlots < ActiveRecord::Migration[8.1]
  def change
    create_table :apply_host_slots, id: false do |t|
      t.string :host_key, null: false, primary_key: true
      t.datetime :next_allowed_at, null: false
      # The apply whose submit took the slot: its own retry may take it again (AcquireHostSlot). Read only through
      # the primary-key row, so no index; no foreign key (a deleted apply's row ages out via PruneApplySteps).
      t.bigint :holder_apply_id, null: false
    end
  end
end
