# frozen_string_literal: true

class CreateFeedbacks < ActiveRecord::Migration[8.1]
  def change
    create_table :feedbacks do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.integer :rating, null: false
      t.text :body, null: false
      t.string :posted_via, null: false, default: 'web'
      t.timestamps
    end

    # The feedback page lists the most recently updated first.
    add_index :feedbacks, :updated_at
    add_check_constraint :feedbacks, 'rating BETWEEN 1 AND 10', name: 'feedbacks_rating_range'
  end
end
