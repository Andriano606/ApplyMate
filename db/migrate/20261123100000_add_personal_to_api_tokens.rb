# frozen_string_literal: true

class AddPersonalToApiTokens < ActiveRecord::Migration[8.1]
  def change
    # The token a user generates for themselves in the "Connect Claude (MCP)" modal.
    # At most one per user; admin-issued tokens stay personal: false.
    add_column :api_tokens, :personal, :boolean, null: false, default: false
    add_index :api_tokens, :user_id, unique: true, where: 'personal', name: 'index_api_tokens_on_user_id_personal'
  end
end
