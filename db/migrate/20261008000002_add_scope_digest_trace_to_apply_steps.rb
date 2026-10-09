# frozen_string_literal: true

class AddScopeDigestTraceToApplySteps < ActiveRecord::Migration[8.1]
  def change
    change_table :apply_steps, bulk: true do |t|
      t.string :scope
      t.string :input_digest
      t.jsonb :trace
    end

    # Runner skip lookup: keyed by step key (the same stage runs in two scopes); state 1 = succeeded.
    add_index :apply_steps, %i[apply_id key input_digest], where: 'state = 1', name: 'index_apply_steps_resume_lookup'
    # PruneApplySteps nulls traces older than TRACE_RETENTION.
    add_index :apply_steps, :finished_at, where: 'trace IS NOT NULL', name: 'index_apply_steps_prunable_trace'
  end
end
