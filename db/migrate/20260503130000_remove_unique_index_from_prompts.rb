# frozen_string_literal: true

class RemoveUniqueIndexFromPrompts < ActiveRecord::Migration[8.1]
  def change
    remove_index :prompts, %i[user_id prompt_type]
  end
end
