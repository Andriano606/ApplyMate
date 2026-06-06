#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require_relative 'conductor_helpers'

$stdout.sync = true
$stderr.sync = true

include ConductorHelpers

# Workspaces claim a port from this range and persist it in .env.development.local.
# We don't use Conductor's CONDUCTOR_PORT because the port has to also be registered
# in Google Cloud Console as an Authorized redirect URI for Google OAuth — and Conductor
# doesn't guarantee a fixed port range. Owning the range ourselves means: register
# http://localhost:3002..3020/auth/google_oauth2/callback in GCP once, every workspace
# lands in that range automatically.
# NB: start at 3002 — docker-compose binds host port 3001 (grafana) and 3100 (loki),
# so the dev server must avoid them. Keep the upper bound below 3100.
WORKSPACE_PORT_RANGE = (3002..3020).freeze

# Runs once when Conductor creates a workspace. Prepares an isolated, runnable
# checkout: its own Postgres DB + Elasticsearch index, installed deps, built assets.
def main
  ensure_asdf_shims_on_path!
  Dir.chdir(workspace_root)

  puts '🚀 Setting up Conductor workspace for ApplyMate'
  puts "   workspace  : #{workspace_name}"
  puts "   dev DB     : #{db_name}"
  puts "   test DB    : #{test_db_name}"
  puts "   ES indexes : vacancies_development_#{workspace_slug} / vacancies_test_#{workspace_slug}"
  puts ''

  copy_secrets_from_root!
  write_env_files
  compose_up!
  wait_for_tcp('localhost', 5432, 'PostgreSQL')
  install_dependencies
  prepare_databases
  build_assets

  port = read_env_value('.env.development.local', 'PORT')
  puts ''
  puts '✅ Workspace setup complete!'
  puts "   dev + test databases/indexes are isolated to this workspace — tests can run in parallel."
  puts "▶️  Click Run to start the dev server (it will serve on http://localhost:#{port})."
  puts ''
  puts "📌 Reminder: register http://localhost:#{WORKSPACE_PORT_RANGE.min}..#{WORKSPACE_PORT_RANGE.max}/auth/google_oauth2/callback"
  puts '   in Google Cloud Console (one-time) so Google OAuth works for every workspace.'
end

# Gitignored secrets (master.key, .env, per-env credential keys) live only in the root
# checkout — git worktree does not copy them into a new workspace. Without master.key
# Rails.application.credentials returns nil for everything, which is why Google OAuth
# fails with "Missing required parameter: client_id" in fresh workspaces. Copy them
# from CONDUCTOR_ROOT_PATH so the workspace boots with the same credentials as root.
def copy_secrets_from_root!
  root = root_path
  if File.expand_path(root) == File.expand_path(workspace_root)
    puts '✅ Workspace IS the root checkout — no secrets to copy'
    return
  end

  secrets = [
    'config/master.key',
    '.env',
    *Dir.glob(File.join(root, 'config/credentials/*.key')).map { |p| p.sub("#{root}/", '') }
  ].uniq

  secrets.each do |rel|
    src = File.join(root, rel)
    dst = File.join(workspace_root, rel)
    next unless File.exist?(src)

    if File.exist?(dst)
      puts "✅ #{rel} already present"
      next
    end

    FileUtils.mkdir_p(File.dirname(dst))
    FileUtils.cp(src, dst)
    File.chmod(0o600, dst) if rel.end_with?('.key')
    puts "✅ Copied #{rel} from root checkout"
  end
end

# Per-workspace isolation is driven by these env vars, read by config/database.yml
# and app/models/vacancy.rb via dotenv-rails at boot. We write BOTH the development
# and the test env so tests in different workspaces never share a database or ES
# index and can run in parallel. (dotenv loads .env.development.local only in dev and
# .env.test.local only in test, so the two never leak into each other.)
def write_env_files
  write_env_file('.env.development.local',
                 'APP_DB_NAME' => db_name,
                 'ES_INDEX_NAMESPACE' => es_index_namespace,
                 'PORT' => pick_port_for_workspace)
  write_env_file('.env.test.local',
                 'APP_TEST_DB_NAME' => test_db_name,
                 'ES_INDEX_NAMESPACE' => es_index_namespace)
end

# Returns the port this workspace should bind to. If one was already claimed (set in
# .env.development.local), reuse it — stable per workspace across restarts. Otherwise
# pick the lowest port in WORKSPACE_PORT_RANGE not claimed by a sibling workspace.
def pick_port_for_workspace
  existing = read_env_value('.env.development.local', 'PORT')
  return existing.to_i if existing && !existing.empty?

  # conductor-linux assigns the port via CONDUCTOR_PORT — honour it so the
  # launcher's sidebar and the running server agree. Falls back to the range
  # scan when launched without it (e.g. the original Conductor app).
  conductor_port = ENV['CONDUCTOR_PORT'].to_i
  return conductor_port if conductor_port.positive?

  taken = sibling_workspace_ports
  free = WORKSPACE_PORT_RANGE.find { |p| !taken.include?(p) }
  unless free
    error_exit(
      "All ports in #{WORKSPACE_PORT_RANGE.min}..#{WORKSPACE_PORT_RANGE.max} are claimed by sibling workspaces.",
      'Archive an unused workspace or widen WORKSPACE_PORT_RANGE in bin/conductor/setup.rb.'
    )
  end
  free
end

def sibling_workspace_ports
  parent = File.dirname(workspace_root)
  self_env = File.join(workspace_root, '.env.development.local')
  Dir.glob(File.join(parent, '*', '.env.development.local'))
     .reject { |path| path == self_env }
     .flat_map { |path| File.readlines(path).filter_map { |line| line[/^PORT=(\d+)/, 1]&.to_i } }
     .uniq
end

# Idempotent: only appends keys that aren't already present.
def write_env_file(relative_path, desired)
  path = File.join(workspace_root, relative_path)
  existing = File.exist?(path) ? File.read(path) : ''

  missing = desired.reject { |key, _| existing.match?(/^#{Regexp.escape(key)}=/) }
  if missing.empty?
    puts "✅ #{relative_path} already configured"
    return
  end

  File.open(path, 'a') do |f|
    f.puts '' unless existing.empty? || existing.end_with?("\n")
    f.puts '# Conductor per-workspace isolation (auto-generated by bin/conductor/setup.rb)'
    missing.each { |key, value| f.puts "#{key}=#{value}" }
  end
  puts "✅ Wrote #{missing.keys.join(', ')} to #{relative_path}"
end

def install_dependencies
  puts ''
  puts '📦 Installing Ruby + JS dependencies...'
  system!('bundle', 'install')
  system!('bun', 'install')
end

def prepare_databases
  puts ''
  puts '🗄️  Preparing databases...'
  puts "   development → #{db_name}"
  # db:prepare maintains the test schema as a side effect, but it runs in the
  # development environment — where APP_TEST_DB_NAME is NOT loaded (it lives in
  # .env.test.local, and dev boot only reads .env.development.local). Without it the
  # test config falls back to the default `apply_mate_test`, so every workspace's
  # db:prepare would create/share that one DB. Pass APP_TEST_DB_NAME explicitly so the
  # test DB it touches is this workspace's namespaced one.
  retry_system!({ 'APP_TEST_DB_NAME' => test_db_name }, 'bin/rails', 'db:prepare')
  # db:prepare only seeds when it creates the DB from scratch, so seed explicitly
  # (Oaken seeds are idempotent via unique_by) to guarantee the dev user exists.
  puts '   seeding development data...'
  retry_system!('bin/rails', 'db:seed')
  # Test DB: schema only, no seeds (Oaken seeds would pollute the test database).
  puts "   test → #{test_db_name} (schema only)"
  retry_system!({ 'RAILS_ENV' => 'test', 'APP_TEST_DB_NAME' => test_db_name }, 'bin/rails', 'db:test:prepare')
end

def build_assets
  puts ''
  puts '🎨 Building assets...'
  system!('bun', 'run', 'build')
  system!('bun', 'run', 'build:css')
end

main
