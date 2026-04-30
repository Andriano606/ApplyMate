# frozen_string_literal: true

class AddDefaultVacancySearchToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :default_vacancy_search, :jsonb
  end
end
