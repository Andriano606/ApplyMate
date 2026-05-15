# frozen_string_literal: true

class AddAiIntegrationToVacancies < ActiveRecord::Migration[8.0]
  def change
    add_reference :vacancies, :ai_integration, null: true, foreign_key: true
  end
end
