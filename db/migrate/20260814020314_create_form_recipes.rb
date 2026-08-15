# frozen_string_literal: true

class CreateFormRecipes < ActiveRecord::Migration[8.0]
  def change
    create_table :form_recipes do |t|
      t.string   :host,             null: false               # normalized, without www
      t.string   :form_fingerprint, null: false               # sha1 of sorted field fingerprints
      t.string   :ats                                         # nil for self-hosted forms
      t.jsonb    :navigation,  null: false, default: []       # [{op: 'click', selector: …}, …]
      t.jsonb    :field_map,   null: false, default: []       # [{fingerprint:, role:, question:}, …]
      t.jsonb    :submit_meta, null: false, default: {}       # {selector:, text:}
      t.integer  :success_count, null: false, default: 0
      t.integer  :fail_count,    null: false, default: 0
      t.datetime :last_success_at
      t.timestamps
    end

    add_index :form_recipes, %i[host form_fingerprint], unique: true
    add_index :form_recipes, :host
  end
end
