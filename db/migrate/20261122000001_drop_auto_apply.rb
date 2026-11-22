# frozen_string_literal: true

# ApplyMate is now a vacancy bank: it keeps the list of live vacancies across job boards up to date (via
# proxies) and nothing else. This drops the whole auto-apply stack — applies, AI integrations, user and
# source profiles, prompts, generated CVs and AI-answered questions — together with the user defaults and
# vacancy columns that only that stack wrote. Irreversible: the dropped rows are user data, not derivable.
class DropAutoApply < ActiveRecord::Migration[8.1]
  # Active Storage owners being removed: Apply (cv, screenshot) and VacancyCv (cv).
  ATTACHMENT_OWNERS = %w[Apply VacancyCv].freeze

  def up
    purge_attachments

    remove_reference :users, :default_profile, foreign_key: { to_table: :user_profiles }, index: false
    remove_reference :users, :default_ai_integration, foreign_key: { to_table: :ai_integrations }, index: false
    remove_reference :users, :default_fill_form_prompt, foreign_key: { to_table: :prompts }, index: true
    remove_reference :users, :default_generate_cv_prompt, foreign_key: { to_table: :prompts }, index: true

    drop_table :applies
    drop_table :vacancy_cvs
    drop_table :vacancy_questions
    drop_table :source_profiles
    drop_table :prompts
    drop_table :ai_integrations
    drop_table :user_profiles

    remove_column :vacancies, :details, :text
    remove_column :vacancies, :external_url, :string
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  # Drops the attachment rows and their blobs in SQL, then deletes the stored files (disk / MinIO) for the
  # blobs that are now unreferenced. Leaving them would orphan every generated CV and apply screenshot.
  def purge_attachments
    owners = ATTACHMENT_OWNERS.map { |owner| connection.quote(owner) }.join(', ')
    blob_ids = select_values(<<~SQL.squish)
      DELETE FROM active_storage_attachments WHERE record_type IN (#{owners}) RETURNING blob_id
    SQL
    return if blob_ids.empty?

    ActiveStorage::Blob.where(id: blob_ids).where.missing(:attachments).find_each(&:purge)
  end
end
