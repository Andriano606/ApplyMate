# frozen_string_literal: true

class AddNameToSourceProfiles < ActiveRecord::Migration[8.1]
  def change
    add_column :source_profiles, :name, :string, null: false
    remove_index :source_profiles, [ :user_id, :source_id ]
  end
end
