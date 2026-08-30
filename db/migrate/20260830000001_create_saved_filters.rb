class CreateSavedFilters < ActiveRecord::Migration[8.1]
  def change
    create_table :saved_filters do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.string :name, null: false
      t.jsonb :vacancy_search, null: false, default: {}
      t.timestamps
    end

    # covers both the per-user listing and the per-user name uniqueness
    add_index :saved_filters, [ :user_id, :name ], unique: true
  end
end
