class RemoveDefaultVacancySearchFromUsers < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :default_vacancy_search, :jsonb
  end
end
