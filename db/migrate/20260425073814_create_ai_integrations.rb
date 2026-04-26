# frozen_string_literal: true

class CreateAiIntegrations < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_integrations do |t|
      t.references :user, null: false, foreign_key: true
      t.string :provider, null: false, default: 'gemini'
      t.text :api_key, null: false
      t.string :model, null: false

      t.timestamps
    end

    add_index :ai_integrations, [ :user_id, :model ], unique: true
  end
end
