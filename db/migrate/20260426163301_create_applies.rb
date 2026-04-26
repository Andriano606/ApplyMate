# frozen_string_literal: true

class CreateApplies < ActiveRecord::Migration[8.1]
  def change
    create_table :applies do |t|
      t.references :user, null: false, foreign_key: true
      t.references :vacancy, null: false, foreign_key: true
      t.references :user_profile, null: false, foreign_key: true
      t.references :ai_integration, null: false, foreign_key: true

      t.timestamps
    end
  end
end
