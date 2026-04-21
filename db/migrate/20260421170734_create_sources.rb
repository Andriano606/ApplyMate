# frozen_string_literal: true

class CreateSources < ActiveRecord::Migration[8.1]
  def change
    create_table :sources do |t|
      t.string :name, null: false
      t.string :base_url, null: false

      t.timestamps
    end
  end
end
