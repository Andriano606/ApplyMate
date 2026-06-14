#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'conductor_helpers'

$stdout.sync = true
$stderr.sync = true

include ConductorHelpers

# Runs on the Conductor "Run" button. Ensures infra + DB are ready, then hands off
# to foreman with the Conductor Procfile (web bound to the workspace's claimed PORT).
def main
  ensure_asdf_shims_on_path!
  Dir.chdir(workspace_root)

  puts '🚀 Starting ApplyMate (Conductor workspace)'
  puts "   database : #{db_name}  |  ES index: vacancies_#{es_index_namespace}"
  puts ''

  compose_up!
  wait_for_tcp('localhost', db_port, 'PostgreSQL')
  wait_for_tcp('localhost', 9200, 'Elasticsearch')

  puts ''
  puts "🗄️  Ensuring #{db_name} exists..."
  retry_system!('bin/rails', 'db:prepare')

  clear_stale_server_pid!
  ensure_foreman!

  # We pass --env /dev/null so foreman skips loading .env (dotenv-rails does that at
  # Rails boot). That means we must export PORT here ourselves — otherwise the
  # ${PORT} in Procfile.conductor stays unexpanded and Rails falls back to 3000.
  port = read_env_value('.env.development.local', 'PORT') || ENV['CONDUCTOR_PORT'] || '3000'
  ENV['PORT'] = port.to_s

  puts ''
  puts "▶️  Starting dev server on http://localhost:#{port}"
  exec('foreman', 'start', '-f', 'Procfile.conductor', '--env', '/dev/null')
end

# A previous Run that wasn't stopped (or crashed / was `kill -9`'d) leaves
# tmp/pids/server.pid behind. If it points at a LIVE process, `bin/rails server`
# refuses to boot ("A server is already running"), exits 1, and foreman tears the
# whole stack down. Stop a live previous server, or drop a stale pid file, so Run
# is always idempotent.
def clear_stale_server_pid!
  pid_file = File.join(workspace_root, 'tmp/pids/server.pid')
  return unless File.exist?(pid_file)

  pid = File.read(pid_file).to_i
  if pid.positive? && process_alive?(pid)
    puts "🛑 Stopping previous dev server (pid #{pid})..."
    Process.kill('TERM', pid)
    sleep 1
  end
  File.delete(pid_file) if File.exist?(pid_file)
end

def process_alive?(pid)
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
rescue Errno::EPERM
  true
end

# Mirrors bin/dev: foreman is a global gem, installed on demand.
def ensure_foreman!
  return unless system('gem list --no-installed --exact --silent foreman')

  puts '📦 Installing foreman...'
  system!('gem', 'install', 'foreman')
  system('asdf', 'reshim', 'ruby') # surface the freshly installed `foreman` shim
end

main
