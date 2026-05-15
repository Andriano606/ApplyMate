# frozen_string_literal: true

class AddProfileAndPromptsToVacancies < ActiveRecord::Migration[8.0]
  def change
    add_reference :vacancies, :user_profile, null: true, foreign_key: true
    add_reference :vacancies, :fill_form_prompt, null: true, foreign_key: { to_table: :prompts }
    add_reference :vacancies, :generate_cv_prompt, null: true, foreign_key: { to_table: :prompts }
  end
end
