# frozen_string_literal: true

class CreateVacancyQuestions < ActiveRecord::Migration[8.1]
  def change
    create_table :vacancy_questions do |t|
      t.references :vacancy,          null: false, foreign_key: true
      t.references :ai_integration,   null: false, foreign_key: true
      t.references :user_profile,     null: false, foreign_key: true
      t.references :fill_form_prompt, null: false, foreign_key: { to_table: :prompts }
      t.text :question, null: false
      t.text :answer
      t.timestamps
    end
  end
end
