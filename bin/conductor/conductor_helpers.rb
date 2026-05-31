# frozen_string_literal: true

require 'socket'

# Shared helpers for the bin/conductor/* workspace lifecycle scripts.
#
# Conductor runs these under a *non-interactive* zsh, so we can't assume an
# interactive shell put the asdf shims (ruby, bundle, rails, gem) on PATH.
# `ensure_asdf_shims_on_path!` fixes that; the rest are conveniences shared by
# setup.rb / run.rb / archive.rb.
module ConductorHelpers
  module_function

  # Repo root (the main checkout). Conductor sets CONDUCTOR_ROOT_PATH; fall back
  # to the current dir when a script is run by hand.
  def root_path
    path = ENV['CONDUCTOR_ROOT_PATH'].to_s
    path.empty? ? Dir.pwd : path
  end

  # The workspace root (where this checkout lives) — two levels up from bin/conductor.
  def workspace_root
    File.expand_path('../..', __dir__)
  end

  def workspace_name
    name = ENV['CONDUCTOR_WORKSPACE_NAME'].to_s
    name.empty? ? File.basename(workspace_root) : name
  end

  # Postgres-identifier- and ES-index-safe slug, e.g. "newport-beach" -> "newport_beach".
  def workspace_slug
    workspace_name.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
  end

  def db_name
    "apply_mate_#{workspace_slug}"
  end

  def test_db_name
    "apply_mate_test_#{workspace_slug}"
  end

  def es_index_namespace
    workspace_slug
  end

  # Read a single KEY=value entry from a workspace env file (e.g. PORT from
  # .env.development.local). Returns the trimmed value, or nil if missing.
  def read_env_value(relative_path, key)
    path = File.join(workspace_root, relative_path)
    return nil unless File.exist?(path)

    File.foreach(path) do |line|
      match = line.match(/^#{Regexp.escape(key)}=(.+)$/)
      return match[1].strip if match
    end
    nil
  end

  # Make the asdf-managed toolchain resolvable for child processes.
  def ensure_asdf_shims_on_path!
    shims = File.join(Dir.home, '.asdf', 'shims')
    return unless Dir.exist?(shims)

    parts = ENV['PATH'].to_s.split(File::PATH_SEPARATOR)
    return if parts.include?(shims)

    ENV['PATH'] = ([ shims ] + parts).join(File::PATH_SEPARATOR)
  end

  # Bring up the single shared Docker stack from the repo root so every workspace
  # talks to the same Postgres/Elasticsearch/MinIO on fixed ports. We deliberately
  # do NOT pass a project name: compose then derives the same default name it uses
  # when run by hand from the root, so this never forks a second, conflicting stack.
  def compose_up!
    root = root_path
    puts '🐳 Starting shared Docker stack from repo root...'
    system!(
      'docker', 'compose',
      '--project-directory', root,
      '-f', File.join(root, 'docker-compose.yml'),
      'up', '-d'
    )
  end

  def wait_for_tcp(host, port, label, timeout: 120)
    print "⏳ Waiting for #{label} (#{host}:#{port}) "
    deadline = Time.now + timeout
    loop do
      begin
        Socket.tcp(host, port, connect_timeout: 2, &:close)
        puts ' ready ✅'
        return
      rescue StandardError
        error_exit("#{label} not reachable on #{host}:#{port} after #{timeout}s") if Time.now > deadline

        print '.'
        sleep 2
      end
    end
  end

  def system!(*args)
    system(*args) || error_exit("Command failed: #{printable(args)}")
  end

  # Like system! but retries — used for `db:prepare` right after Postgres' TCP port
  # opens, since the server briefly refuses connections while it finishes starting.
  def retry_system!(*args, attempts: 5, sleep_seconds: 3)
    attempts.times do |i|
      return if system(*args)

      warn "   attempt #{i + 1}/#{attempts} failed; retrying in #{sleep_seconds}s..."
      sleep sleep_seconds
    end
    error_exit("Command failed after #{attempts} attempts: #{printable(args)}")
  end

  def printable(args)
    args.reject { |a| a.is_a?(Hash) }.join(' ')
  end

  def error_exit(message, hint = nil)
    warn "❌ #{message}"
    warn "   #{hint}" if hint
    exit 1
  end
end
