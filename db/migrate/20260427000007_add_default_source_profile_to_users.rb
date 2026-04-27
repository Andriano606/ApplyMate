# frozen_string_literal: true

class AddDefaultSourceProfileToUsers < ActiveRecord::Migration[8.1]
  def change
    add_reference :users, :default_source_profile, null: true, foreign_key: { to_table: :source_profiles }
  end
end
