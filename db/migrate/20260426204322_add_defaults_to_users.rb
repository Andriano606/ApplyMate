# frozen_string_literal: true

class AddDefaultsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :default_profile_id, :bigint
    add_column :users, :default_ai_integration_id, :bigint

    add_foreign_key :users, :user_profiles, column: :default_profile_id
    add_foreign_key :users, :ai_integrations, column: :default_ai_integration_id
  end
end
