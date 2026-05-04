# frozen_string_literal: true

class CreatePrompts < ActiveRecord::Migration[8.1]
  def change
    create_table :prompts do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :prompt_type, null: false
      t.text :content, null: false

      t.timestamps
    end

    add_index :prompts, %i[user_id prompt_type], unique: true
  end
end
