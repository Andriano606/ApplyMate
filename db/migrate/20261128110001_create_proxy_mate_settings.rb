# frozen_string_literal: true

# Singleton: the ProxyMate URL + API key an admin pastes in by hand. At most one row, enforced by a
# unique index on the constant `singleton` column (a second concurrent first-save hits
# RecordNotUnique, see ProxyMateSetting.instance) plus a CHECK that the constant stays true.
class CreateProxyMateSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :proxy_mate_settings do |t|
      t.boolean :singleton, null: false, default: true
      t.string :url
      t.text :api_key # Active Record encryption (ciphertext is longer than the key)
      t.timestamps
    end

    add_index :proxy_mate_settings, :singleton, unique: true
    add_check_constraint :proxy_mate_settings, 'singleton', name: 'proxy_mate_settings_singleton'
  end
end
