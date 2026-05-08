# frozen_string_literal: true

# When using the 'async' gem with ActiveRecord, we must ensure that the execution state
# (including database connections) is isolated per Fiber rather than per Thread.
# This prevents multiple Fibers from sharing and corrupting the same database connection.
ActiveSupport::IsolatedExecutionState.isolation_level = :fiber
