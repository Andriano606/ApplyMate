# frozen_string_literal: true

class AddFactsToUserProfiles < ActiveRecord::Migration[8.1]
  def change
    add_column :user_profiles, :facts, :jsonb
    add_column :user_profiles, :facts_cv_digest, :string
  end
end
