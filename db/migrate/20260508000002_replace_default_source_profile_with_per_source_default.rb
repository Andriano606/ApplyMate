# frozen_string_literal: true

class ReplaceDefaultSourceProfileWithPerSourceDefault < ActiveRecord::Migration[8.0]
  def up
    remove_foreign_key :users, column: :default_source_profile_id
    remove_index :users, :default_source_profile_id
    remove_column :users, :default_source_profile_id

    add_column :source_profiles, :is_default, :boolean, default: false, null: false

    add_index :source_profiles, [ :user_id, :source_id ],
              unique: true,
              where: '"is_default" = true',
              name: 'index_source_profiles_on_user_source_default'
  end

  def down
    remove_index :source_profiles, name: 'index_source_profiles_on_user_source_default'
    remove_column :source_profiles, :is_default

    add_column :users, :default_source_profile_id, :bigint
    add_index :users, :default_source_profile_id, name: 'index_users_on_default_source_profile_id'
    add_foreign_key :users, :source_profiles, column: :default_source_profile_id
  end
end
