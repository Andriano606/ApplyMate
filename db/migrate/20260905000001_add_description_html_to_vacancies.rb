class AddDescriptionHtmlToVacancies < ActiveRecord::Migration[8.1]
  def change
    add_column :vacancies, :description_html, :text
  end
end
