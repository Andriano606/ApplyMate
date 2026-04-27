# frozen_string_literal: true

class AddFormDataToApplies < ActiveRecord::Migration[8.1]
  def change
    add_column :applies, :form_data, :jsonb
  end
end
