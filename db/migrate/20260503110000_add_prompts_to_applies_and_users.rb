# frozen_string_literal: true

class AddPromptsToAppliesAndUsers < ActiveRecord::Migration[8.1]
  def change
    add_reference :applies, :fill_form_prompt, foreign_key: { to_table: :prompts }, null: true
    add_reference :applies, :generate_cv_prompt, foreign_key: { to_table: :prompts }, null: true

    add_reference :users, :default_fill_form_prompt, foreign_key: { to_table: :prompts }, null: true
    add_reference :users, :default_generate_cv_prompt, foreign_key: { to_table: :prompts }, null: true
  end
end
