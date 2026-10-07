# frozen_string_literal: true

# browserd could not be reached or answered something other than 201/503 (401 token mismatch,
# 500 launch_failed, a timeout, connection refused). Treated as transient by the caller.
class ApplyMate::Client::Browser::Crashed < StandardError
end
