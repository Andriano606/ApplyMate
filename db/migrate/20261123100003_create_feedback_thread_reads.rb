# frozen_string_literal: true

class CreateFeedbackThreadReads < ActiveRecord::Migration[8.1]
  def change
    # How far each participant (the feedback's author, anyone who replied) has
    # read a thread; replies by others after seen_at are "new" for them.
    create_table :feedback_thread_reads do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.references :feedback, null: false, foreign_key: true
      t.datetime :seen_at, null: false
      t.timestamps
    end

    add_index :feedback_thread_reads, %i[user_id feedback_id], unique: true
  end
end
