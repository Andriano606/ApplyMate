# frozen_string_literal: true

class AddClientToSources < ActiveRecord::Migration[8.1]
  def change
    add_column :sources, :client, :string
  end
end
