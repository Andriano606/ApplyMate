# frozen_string_literal: true

class RenamePayloadToFilledFormDataOnApplies < ActiveRecord::Migration[8.1]
  def change
    rename_column :applies, :payload, :filled_form_data
  end
end
