# frozen_string_literal: true

# Apply engine v2, phase 1 columns only. Columns no phase-1 code writes (ai_calls*, platform*, apply_key, entry_url,
# form_url, navigation, fields, answers, answers_approved_digest, reviewed_at, duplicate_confirmed_at,
# input_request/response, apply_recipe_id) are added by phases 3a/3b/6 in their own migrations.
class ApplyEngineState < ActiveRecord::Migration[8.1]
  LEGACY_FAILED = [ 10, 17, 8, 12, 14, 5, 6 ].freeze # failed_* values of the old status enum
  LEGACY_COMPLETED = 4
  LEGACY_SENDING = 3 # sending_cv: the old SendApply may already have clicked

  def up
    change_table :applies, bulk: true do |t|
      t.integer  :state # nullable first: backfill before NOT NULL / indexes
      t.string   :stage
      t.integer  :attempt, null: false, default: 0
      t.uuid     :run_token
      t.string   :job_id
      t.jsonb    :failure
      t.datetime :heartbeat_at
      t.datetime :deadline_at
      t.datetime :submit_claimed_at
      t.datetime :submitted_at
      t.string   :submitted_via # engine | manual
    end

    execute <<~SQL.squish
      UPDATE applies SET
        state = CASE WHEN status = #{LEGACY_COMPLETED} THEN 5
                     WHEN status = #{LEGACY_SENDING} THEN 8
                     ELSE 6 END,
        submit_claimed_at = CASE WHEN status = #{LEGACY_SENDING} THEN updated_at END,
        submitted_at = CASE WHEN status = #{LEGACY_COMPLETED} THEN updated_at END,
        submitted_via = CASE WHEN status = #{LEGACY_COMPLETED} THEN 'engine' END,
        failure = CASE WHEN status IN (#{LEGACY_FAILED.join(',')})
                         THEN jsonb_build_object('code', 'legacy_failure', 'legacy_status', status, 'detail', error)
                       WHEN status = #{LEGACY_SENDING}
                         THEN jsonb_build_object('code', 'outcome_unknown', 'legacy_status', status)
                       WHEN status IS DISTINCT FROM #{LEGACY_COMPLETED}
                         THEN jsonb_build_object('code', 'worker_lost', 'legacy_status', status)
                  END
    SQL

    # Several legacy sending_cv rows for one (user, vacancy): keep the newest claim, older ones become failed.
    execute <<~SQL.squish
      UPDATE applies a SET submit_claimed_at = NULL, state = 6
        FROM applies b
       WHERE a.state = 8 AND b.state = 8 AND a.user_id = b.user_id AND a.vacancy_id = b.vacancy_id AND a.id < b.id
    SQL

    change_column_null :applies, :state, false
    change_column_default :applies, :state, from: nil, to: 0

    # Literal ints mirror Apply::ACTIVE_STATES; spec/models/apply_indexes_spec.rb compares indexdef with the enum.
    add_index :applies, %i[user_id vacancy_id], unique: true, where: 'state IN (0, 1, 2, 3, 4)',
                                                name: 'index_applies_one_active_per_vacancy'
    add_index :applies, %i[user_id vacancy_id], unique: true,
                                                where: 'submit_claimed_at IS NOT NULL AND submitted_at IS NULL AND state <> 9',
                                                name: 'index_applies_one_open_claim_per_vacancy'
    add_index :applies, %i[user_id state], name: 'index_applies_on_user_state' # attention inbox
    add_index :applies, %i[user_id created_at], name: 'index_applies_on_user_created' # daily limit
    add_index :applies, 'COALESCE(heartbeat_at, updated_at)', where: 'state IN (0, 1, 2)',
                                                              name: 'index_applies_stale_candidates'
    add_index :applies, :updated_at, where: 'state IN (3, 4)', name: 'index_applies_waiting_updated'
  end

  def down
    %w[index_applies_waiting_updated index_applies_stale_candidates index_applies_on_user_created
       index_applies_on_user_state index_applies_one_open_claim_per_vacancy
       index_applies_one_active_per_vacancy].each do |name|
      remove_index :applies, name:
    end

    change_table :applies, bulk: true do |t|
      t.remove :state, :stage, :attempt, :run_token, :job_id, :failure, :heartbeat_at, :deadline_at,
               :submit_claimed_at, :submitted_at, :submitted_via
    end
  end
end
