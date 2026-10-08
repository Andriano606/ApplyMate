# frozen_string_literal: true

# AcquireHostSlot found the tenant's host slot taken: the run may try again at `until`. Not a failure of the apply:
# the Runner parks it in waiting_capacity (like PoolBusy) and Apply::Job::Apply retries the job at that time.
class Apply::Operation::Engine::Throttled < StandardError
  attr_reader :until

  def initialize(until:)
    @until = binding.local_variable_get(:until)
    super("host slot taken until #{@until.iso8601}")
  end
end
