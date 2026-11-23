# frozen_string_literal: true

class CreateFeedbackReplies < ActiveRecord::Migration[8.1]
  def change
    create_table :feedback_replies do |t|
      t.references :feedback, null: false, foreign_key: true, index: false
      t.references :user, null: false, foreign_key: true
      t.text :body, null: false
      t.timestamps
    end

    # A thread is read in posting order.
    add_index :feedback_replies, %i[feedback_id created_at]
  end
end
