# frozen_string_literal: true

class AddReviewPolicyToUsers < ActiveRecord::Migration[8.1]
  def change
    # enum always 0, unknown_platforms 1, never 2 (default NEVER)
    add_column :users, :review_policy, :integer, null: false, default: 2
    add_column :users, :auto_consent, :boolean, null: false, default: true
  end
end
