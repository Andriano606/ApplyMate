# frozen_string_literal: true

# Hiding vacancies was removed; the block keeps the migration reversible.
class DropHiddenVacancies < ActiveRecord::Migration[8.1]
  def change
    drop_table :hidden_vacancies do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.references :vacancy, null: false, foreign_key: true
      t.timestamps
      t.index [ :user_id, :vacancy_id ], unique: true
    end
  end
end
