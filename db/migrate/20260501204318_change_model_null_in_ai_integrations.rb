# frozen_string_literal: true

class ChangeModelNullInAiIntegrations < ActiveRecord::Migration[8.1]
  def change
    change_column_null :ai_integrations, :model, true
  end
end
