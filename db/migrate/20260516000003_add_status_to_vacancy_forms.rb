# frozen_string_literal: true

class AddStatusToVacancyForms < ActiveRecord::Migration[8.1]
  def change
    add_column :vacancy_forms, :status, :integer, null: false, default: 0
    add_column :vacancy_forms, :error,  :text
  end
end
