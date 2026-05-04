# frozen_string_literal: true

class AddNameToPrompts < ActiveRecord::Migration[8.1]
  def change
    add_column :prompts, :name, :string, null: false, default: ''
  end
end
