# frozen_string_literal: true

# Development-only request watchdog.
#
# With `config.enable_reloading = true`, the code reloader takes the load
# interlock exclusively on the first request after a file change. If another
# request is parked in a no-timeout blocking call (external HTTP, Ferrum/Chrome,
# a stuck socket) it holds the interlock in "sharing" mode, so the reload — and
# then every following request — waits forever on a ConditionVariable that has no
# deadline. Once all Puma threads are parked, new connections sit in the accept
# backlog and never reach the logger: the browser spins forever and the log is
# silent. (Connection-pool exhaustion can't cause this — checkout times out at 5s
# and logs.)
#
# rack-timeout caps how long a single request may run. When exceeded it raises in
# that thread, which unwinds the stuck request, releases the interlock permit so
# the server recovers on its own, and logs the request + backtrace so the real
# hanging call can be found and fixed.
#
# The gem lives in the :development bundle group, so its railtie (which inserts
# the middleware) is only present in development — never in test/staging/production.
# It reads its config from ENV at boot, so we set the defaults here:
#   - service_timeout 25s: generous enough not to kill legitimately slow dev
#     requests (Elasticsearch search, live Turbo re-render), short enough that a
#     true hang recovers quickly instead of spinning forever.
#   - wait_timeout 0 (disabled): don't expire requests for time spent queued
#     behind a busy thread pool — that's not a hang, just contention.
if Rails.env.development? && defined?(Rack::Timeout)
  ENV['RACK_TIMEOUT_SERVICE_TIMEOUT'] ||= '25'
  ENV['RACK_TIMEOUT_WAIT_TIMEOUT']    ||= '0'

  # Quiet by default (rack-timeout logs every request at INFO); only surface the
  # timeout/expiry events, which is exactly the hang we care about.
  Rack::Timeout::Logger.level = Logger::WARN
end
