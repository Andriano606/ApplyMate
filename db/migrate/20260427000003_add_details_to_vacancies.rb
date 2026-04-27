# frozen_string_literal: true

class AddDetailsToVacancies < ActiveRecord::Migration[8.0]
  def change
    add_column :vacancies, :details, :text
  end
end
