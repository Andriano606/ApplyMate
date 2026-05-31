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
  ok = system({ 'RAILS_ENV' => env, 'DISABLE_DATABASE_ENVIRONMENT_CHECK' => '1' }, 'bin/rails', 'db:drop')
  warn "⚠️  #{env}: could not drop database (Postgres down or already gone) — skipping." unless ok
end

main
