class CreateHiddenVacancies < ActiveRecord::Migration[8.1]
  def change
    create_table :hidden_vacancies do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.references :vacancy, null: false, foreign_key: true
      t.timestamps
    end

    # one row per (user, vacancy); also serves the per-user lookup that feeds the search exclusion
    add_index :hidden_vacancies, [ :user_id, :vacancy_id ], unique: true
  end
end
