class AddPendingDescriptionIndexToVacancies < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Phase 2 of SyncVacancies walks each source's vacancies by id cursor looking for the
  # ones still missing markup. Without a partial index that cursor scans forward over
  # every already-filled row (~1M) on every run; with it the scan visits only the rows
  # the pass is actually going to fetch.
  def change
    add_index :vacancies, [ :source_id, :id ],
              where: "description_html IS NULL OR description_html = ''",
              name: 'index_vacancies_pending_description_html',
              algorithm: :concurrently
  end
end
