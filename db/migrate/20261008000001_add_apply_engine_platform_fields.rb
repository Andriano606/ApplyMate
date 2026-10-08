# frozen_string_literal: true

class AddApplyEnginePlatformFields < ActiveRecord::Migration[8.1]
  def change
    change_table :applies, bulk: true do |t|
      t.string :platform
      t.jsonb :platform_match
      t.string :apply_key
      t.string :entry_url
      t.string :form_url
      t.jsonb :navigation
      t.jsonb :fields
      t.jsonb :answers
      t.string :answers_approved_digest
      t.datetime :reviewed_at
      t.datetime :duplicate_confirmed_at
    end

    # already_applied check (same user + same platform apply_key)
    add_index :applies, %i[user_id apply_key], where: 'apply_key IS NOT NULL', name: 'index_applies_on_user_apply_key'
  end
end
