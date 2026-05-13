# frozen_string_literal: true

class AddFailCountToProxies < ActiveRecord::Migration[8.0]
  def change
    add_column :proxies, :fail_count, :integer, default: 0, null: false
  end
end
