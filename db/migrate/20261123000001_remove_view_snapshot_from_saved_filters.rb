# frozen_string_literal: true

# The "+appeared / −disappeared since last view" badges on saved-filter pills
# are gone; these columns only held the snapshot they were computed from.
class RemoveViewSnapshotFromSavedFilters < ActiveRecord::Migration[8.1]
  def change
    remove_column :saved_filters, :last_seen_count, :integer
    remove_column :saved_filters, :last_seen_max_vacancy_id, :bigint
  end
end
