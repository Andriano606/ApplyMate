#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'conductor_helpers'

$stdout.sync = true
$stderr.sync = true

include ConductorHelpers

# Runs before Conductor archives a workspace. Tears down only THIS workspace's
# isolated resources (DB + ES index); the shared Docker stack is left running for
# other workspaces. Best-effort: a failure must not block archiving, so we warn
# rather than abort.
def main
  ensure_asdf_shims_on_path!
  Dir.chdir(workspace_root)

  puts '📦 Archiving ApplyMate Conductor workspace'
  puts "   databases  : #{db_name}, #{test_db_name}"
  puts "   ES indexes : vacancies_development_#{workspace_slug}, vacancies_test_#{workspace_slug}"
  puts ''

  %w[development test].each do |env|
    delete_es_index(env)
    drop_database(env)
  end

  puts ''
  puts '✅ Per-workspace resources cleaned up (shared Docker stack left running).'
end

def delete_es_index(env)
  ok = system({ 'RAILS_ENV' => env }, 'bin/rails', 'runner', 'Vacancy.__elasticsearch__.delete_index!')
  warn "⚠️  #{env}: could not delete ES index (Elasticsearch down or index absent) — skipping." unless ok
end

def drop_database(env)
  # db:drop drops the current env's DB AND the test DB in one go. In the development
  # env APP_TEST_DB_NAME isn't loaded (it lives in .env.test.local), so without it the
  # test config falls back to the default `apply_mate_test` — and we'd drop that SHARED
  # DB out from under the root checkout and every sibling workspace. Pass APP_TEST_DB_NAME
  # explicitly so we only ever drop this workspace's namespaced test DB.
  ok = system(
    { 'RAILS_ENV' => env, 'APP_TEST_DB_NAME' => test_db_name, 'DISABLE_DATABASE_ENVIRONMENT_CHECK' => '1' },
    'bin/rails', 'db:drop'
  )
  warn "⚠️  #{env}: could not drop database (Postgres down or already gone) — skipping." unless ok
end

main
