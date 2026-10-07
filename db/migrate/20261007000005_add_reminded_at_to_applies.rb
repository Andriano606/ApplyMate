# frozen_string_literal: true

# 48 h reminder for applies waiting on the user (design §11.3, Apply::Operation::Engine::ExpireWaiting).
# A reminder is due while reminded_at is NULL or older than updated_at: every transition bumps updated_at, so a row
# that re-enters needs_human / needs_review becomes due again without any reset code. The partial index mirrors
# Apply::WAITING_STATES (spec/models/apply_indexes_spec.rb) and Apply::REMINDER_DUE_SQL.
class AddRemindedAtToApplies < ActiveRecord::Migration[8.1]
  def change
    add_column :applies, :reminded_at, :datetime
    add_index :applies, :updated_at, where: 'state IN (3, 4) AND (reminded_at IS NULL OR reminded_at < updated_at)',
                                     name: 'index_applies_remind_candidates'
  end
end
