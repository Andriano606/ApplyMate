# frozen_string_literal: true

class RemoveFillFormPromptFromVacancies < ActiveRecord::Migration[8.0]
  def change
    remove_reference :vacancies, :fill_form_prompt, foreign_key: { to_table: :prompts }
  end
end
