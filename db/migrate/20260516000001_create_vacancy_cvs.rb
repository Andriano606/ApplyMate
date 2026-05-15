# frozen_string_literal: true

class CreateVacancyCvs < ActiveRecord::Migration[8.1]
  def change
    create_table :vacancy_cvs do |t|
      t.references :vacancy,              null: false, foreign_key: true
      t.references :ai_integration,       null: false, foreign_key: true
      t.references :user_profile,         null: false, foreign_key: true
      t.references :generate_cv_prompt,   null: false, foreign_key: { to_table: :prompts }
      t.timestamps
    end

    remove_reference :vacancies, :ai_integration,     foreign_key: true
    remove_reference :vacancies, :user_profile,       foreign_key: true
    remove_reference :vacancies, :generate_cv_prompt, foreign_key: { to_table: :prompts }
  end
end
