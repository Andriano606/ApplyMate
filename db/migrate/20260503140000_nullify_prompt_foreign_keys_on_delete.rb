# frozen_string_literal: true

class NullifyPromptForeignKeysOnDelete < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :applies, column: :fill_form_prompt_id
    remove_foreign_key :applies, column: :generate_cv_prompt_id
    remove_foreign_key :users, column: :default_fill_form_prompt_id
    remove_foreign_key :users, column: :default_generate_cv_prompt_id

    add_foreign_key :applies, :prompts, column: :fill_form_prompt_id, on_delete: :nullify
    add_foreign_key :applies, :prompts, column: :generate_cv_prompt_id, on_delete: :nullify
    add_foreign_key :users, :prompts, column: :default_fill_form_prompt_id, on_delete: :nullify
    add_foreign_key :users, :prompts, column: :default_generate_cv_prompt_id, on_delete: :nullify
  end
end
