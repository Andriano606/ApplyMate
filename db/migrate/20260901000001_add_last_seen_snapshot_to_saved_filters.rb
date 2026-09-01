class AddLastSeenSnapshotToSavedFilters < ActiveRecord::Migration[8.1]
  def change
    # Snapshot taken when the user last viewed the filter's results:
    # appeared = matching vacancies with id > last_seen_max_vacancy_id,
    # disappeared = last_seen_count + appeared - current count.
    add_column :saved_filters, :last_seen_count, :integer
    add_column :saved_filters, :last_seen_max_vacancy_id, :bigint
  end
end
