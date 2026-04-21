# frozen_string_literal: true

class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table "users", force: :cascade do |t|
      t.boolean "admin", default: false, null: false
      t.string "avatar_url"
      t.datetime "created_at", null: false
      t.string "email", null: false
      t.string "middle_name"
      t.string "name", null: false
      t.string "provider", null: false
      t.string "uid", null: false
      t.datetime "updated_at", null: false
      t.index [ "email" ], name: "index_users_on_email"
      t.index [ "provider", "uid" ], name: "index_users_on_provider_and_uid", unique: true
    end
  end
end
