# frozen_string_literal: true

class RemoveUniqueIndexFromAiIntegrations < ActiveRecord::Migration[8.1]
  def change
    remove_index :ai_integrations, [ :user_id, :model ], unique: true
  end
end
