# frozen_string_literal: true

# ApplyEngineState copied status/error into state/failure; nothing reads or writes them afterwards.
class RemoveLegacyStatusFromApplies < ActiveRecord::Migration[8.1]
  def change
    remove_column :applies, :status, :integer
    remove_column :applies, :error, :text
  end
end
