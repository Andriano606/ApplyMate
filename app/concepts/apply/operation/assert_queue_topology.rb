# frozen_string_literal: true

# Boot-time guard for config/queue.yml (see .ai/docs/architecture.md, "Queue topology") and, for the
# dedicated apply worker, its primary DB pool (config/database.yml, see .ai/docs/apply_engine.md, "Heartbeat").
# File-only: no DB access, so it is safe during assets:precompile.
class Apply::Operation::AssertQueueTopology < ApplyMate::Operation::Base
  class Violation < StandardError; end

  APPLY_QUEUE = 'apply'
  CONFIG_PATH = Rails.root.join('config/queue.yml')
  ROLES = %w[general apply all].freeze

  # The single reader of APPLY_SLOTS (config/queue.yml calls this for the apply worker's
  # `threads`): how many applies may run concurrently on this host (dev 1, staging 3).
  # Anything but a positive integer raises, so a typo cannot render `threads: 0`.
  def self.apply_slots
    slots = Integer(ENV.fetch('APPLY_SLOTS', '1'), exception: false)
    return slots if slots&.positive?

    raise Violation, "APPLY_SLOTS=#{ENV.fetch('APPLY_SLOTS').inspect} must be a positive integer"
  end

  # The single reader of SQ_ROLE (config/queue.yml calls this to pick the workers):
  # general | apply | all, default all. Anything else raises: queue.yml renders the apply
  # worker for every role but `general`, so a typo such as `generl` on the Kamal `worker`
  # role would otherwise start a second apply worker beside the apply_worker container.
  def self.role
    role = ENV.fetch('SQ_ROLE', 'all')
    return role if ROLES.include?(role)

    raise Violation, "SQ_ROLE=#{role.inspect} is not one of #{ROLES.join(' | ')}"
  end

  # Every apply-worker thread holds one primary connection for its run and one for that run's heartbeat
  # ticker (Apply::Operation::Engine::Heartbeat), plus 2 for Rails/Solid Queue internals.
  def self.required_primary_pool
    (2 * apply_slots) + 2
  end

  # max_connections of this env's primary database config (parsed config, no connection).
  def self.primary_pool_size
    ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: 'primary')&.max_connections
  end

  def perform!(workers: nil, **)
    skip_authorize
    self.class.role

    workers = normalize(workers || load_workers)

    assert_no_wildcards!(workers)
    apply_workers = workers.select { |worker| worker[:queues].include?(APPLY_QUEUE) }
    assert_single_apply_worker!(apply_workers)
    assert_apply_worker_shape!(apply_workers.first)
    assert_role_matches!(apply_workers)
    assert_primary_pool_fits!

    self.model = workers
  end

  private

  def load_workers
    config = ActiveSupport::ConfigurationFile.parse(CONFIG_PATH).deep_symbolize_keys
    config = config[Rails.env.to_sym] || config

    Array(config[:workers])
  end

  def normalize(workers)
    workers.map do |worker|
      worker = worker.to_h.deep_symbolize_keys
      worker.merge(queues: Array(worker[:queues]).map(&:to_s))
    end
  end

  def assert_no_wildcards!(workers)
    offender = workers.find { |worker| worker[:queues].any? { |queue| queue.include?('*') } }
    return unless offender

    raise Violation, "worker #{offender.inspect} lists a wildcard queue; '*' would drain the apply queue"
  end

  def assert_single_apply_worker!(apply_workers)
    return if apply_workers.size <= 1

    raise Violation, "#{apply_workers.size} workers serve the apply queue, expected one: #{apply_workers.inspect}"
  end

  def assert_apply_worker_shape!(worker)
    return unless worker

    if worker.fetch(:processes, 1).to_i != 1
      raise Violation, "apply worker #{worker.inspect} must run exactly 1 process"
    end

    return if worker[:threads].to_i == self.class.apply_slots

    raise Violation, "apply worker #{worker.inspect} threads must equal APPLY_SLOTS (#{self.class.apply_slots})"
  end

  # Only the dedicated apply worker (SQ_ROLE=apply): with `all` the same boot check runs in puma too, whose pool
  # is sized for web threads, and dev/Conductor (`all`) pools are far above the minimum.
  def assert_primary_pool_fits!
    return unless self.class.role == 'apply'

    pool = self.class.primary_pool_size
    return if pool.nil? || pool >= self.class.required_primary_pool

    raise Violation, "SQ_ROLE=apply with APPLY_SLOTS=#{self.class.apply_slots} needs a primary pool of at least " \
                     "#{self.class.required_primary_pool} (2 * APPLY_SLOTS + 2), config has #{pool}"
  end

  def assert_role_matches!(apply_workers)
    role = self.class.role

    if %w[apply all].include?(role) && apply_workers.empty?
      raise Violation, "SQ_ROLE=#{role} requires a worker serving the apply queue"
    end

    return unless role == 'general' && apply_workers.any?

    raise Violation, "SQ_ROLE=general must not serve the apply queue: #{apply_workers.first.inspect}"
  end
end
