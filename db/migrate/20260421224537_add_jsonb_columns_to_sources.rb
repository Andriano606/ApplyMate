# frozen_string_literal: true

class AddJsonbColumnsToSources < ActiveRecord::Migration[8.1]
  def change
    add_column :sources, :selectors, :jsonb, default: {}
    add_column :sources, :urls, :jsonb, default: {}
  end
end
