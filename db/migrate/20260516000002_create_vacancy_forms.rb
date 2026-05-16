# frozen_string_literal: true

class CreateVacancyForms < ActiveRecord::Migration[8.1]
  def change
    create_table :vacancy_forms do |t|
      t.references :vacancy,          null: false, foreign_key: true
      t.references :user_profile,     null: false, foreign_key: true
      t.references :ai_integration,   null: false, foreign_key: true
      t.references :fill_form_prompt, null: false, foreign_key: { to_table: :prompts }
      t.jsonb      :form_data,        null: false, default: {}
      t.timestamps
    end
  end
end
