# frozen_string_literal: true

# trace / ai token counters / round / input_digest are added by the phases that write them.
class CreateApplySteps < ActiveRecord::Migration[8.1]
  def change
    create_table :apply_steps do |t|
      t.references :apply, null: false, foreign_key: true, index: false
      t.integer  :attempt, null: false
      t.string   :key, null: false
      t.string   :stage, null: false
      t.integer  :position, null: false
      t.integer  :state, null: false, default: 0 # running succeeded failed skipped
      t.jsonb    :result
      t.string   :error_code
      t.text     :error_detail
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.timestamps

      t.index %i[apply_id attempt key], unique: true
      t.index :finished_at, name: 'index_apply_steps_on_finished_at' # pruning
    end
  end
end
