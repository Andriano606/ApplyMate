# frozen_string_literal: true

class CreateVacancies < ActiveRecord::Migration[8.1]
  def change
    create_table :vacancies do |t|
      t.references :source, null: false, foreign_key: true
      t.string :title
      t.string :url
      t.string :company_name
      t.string :company_icon_url
      t.text :description
      t.string :external_id

      t.timestamps
    end

    add_index :vacancies, [ :source_id, :external_id ], unique: true
  end
end
