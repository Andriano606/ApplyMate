# frozen_string_literal: true

class AddScraperToSources < ActiveRecord::Migration[8.1]
  def change
    add_column :sources, :scraper, :string
  end
end
