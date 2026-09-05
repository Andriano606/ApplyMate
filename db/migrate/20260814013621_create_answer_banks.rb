# frozen_string_literal: true

class CreateAnswerBanks < ActiveRecord::Migration[8.0]
  def change
    create_table :answer_banks do |t|
      t.references :user_profile, null: false, foreign_key: true
      t.string  :role,   null: false             # canonical role or 'custom_question'
      t.text    :question                        # normalized question text for custom_question
      t.text    :answer, null: false
      t.integer :source, null: false, default: 0 # enum: manual / ai_generated / imported
      t.timestamps
    end

    add_index :answer_banks, %i[user_profile_id role]
    add_index :answer_banks, %i[user_profile_id question]
  end
end
