# frozen_string_literal: true

class RemoveClientSelectorsUrlsFromSources < ActiveRecord::Migration[8.0]
  def change
    remove_column :sources, :client, :string
    remove_column :sources, :selectors, :jsonb
    remove_column :sources, :urls, :jsonb
  end
end
