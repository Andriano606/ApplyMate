# frozen_string_literal: true

# browserd answered 503 (all MAX_BROWSERS slots taken) for every AcquireLease attempt. Transient: the
# caller waits for capacity (the apply job's retry / waiting_capacity), it never fails the apply.
class ApplyMate::Client::Browser::PoolBusy < StandardError
end
