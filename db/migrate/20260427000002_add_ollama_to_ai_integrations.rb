# frozen_string_literal: true

class AddOllamaToAiIntegrations < ActiveRecord::Migration[8.1]
  def change
    change_column_null :ai_integrations, :api_key, true
    add_column :ai_integrations, :host, :string
  end
end
