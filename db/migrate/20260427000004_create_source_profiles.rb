# frozen_string_literal: true

class CreateSourceProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :source_profiles do |t|
      t.references :user, null: false, foreign_key: true
      t.references :source, null: false, foreign_key: true
      t.integer :auth_method, null: false, default: 0
      t.string :session_id

      t.timestamps
    end

    add_index :source_profiles, [ :user_id, :source_id ], unique: true
  end
end
