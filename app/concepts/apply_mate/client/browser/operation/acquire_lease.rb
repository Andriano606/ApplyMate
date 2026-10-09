# frozen_string_literal: true

# POST /leases on browserd. model = ApplyMate::Client::Browser::Lease (its expires_at reflects the granted TTL).
#
# Termination: 503 (pool busy) is retried at most BUSY_ATTEMPTS POSTs in total, sleeping the server's
# Retry-After (default 5 s, capped at 10 s; via Clock.sleep_ms) between them, so a full pool costs ≤ ~20 s of
# sleep plus the POSTs, then raises PoolBusy. Anything else is not retried here: 401 / 4xx / 5xx / connection errors /
# timeouts raise Crashed (transient; the caller's job retry decides). A missing BROWSERD_URL/TOKEN raises
# KeyError (configuration, not transient).
#
# POST waits for the browser launch, which browserd caps at 60 s (+ up to 10 s teardown before its 500),
# hence LAUNCH_TIMEOUT_S instead of the client's default 20 s; a shorter client timeout would abandon
# launches the server is about to complete.
#
# The lease's playwright_version must equal the pinned gem's COMPATIBLE_PLAYWRIGHT_VERSION: the Ruby
# client sends no Playwright UA, so playwright-core would not reject a mismatch itself. On mismatch the
# lease is released and VersionMismatch (permanent) raised.
class ApplyMate::Client::Browser::Operation::AcquireLease < ApplyMate::Operation::Base
  BUSY_ATTEMPTS = 3
  DEFAULT_RETRY_AFTER_S = 5
  MAX_RETRY_AFTER_S = 10
  LAUNCH_TIMEOUT_S = 75

  # ttl_s: the lease lifetime asked for (browserd clamps it to [60, LEASE_TTL_S]); nil = browserd's LEASE_TTL_S.
  def perform!(owner:, humanize: false, identity: nil, ttl_s: nil, **)
    skip_authorize
    http = ApplyMate::Client::Browser::Browserd.http
    payload = { owner:, humanize:, identity: }
    payload[:ttl_s] = ttl_s if ttl_s
    lease = parse_lease(request_lease(http, JSON.generate(payload)))
    assert_compatible!(lease)
    self.model = lease
  end

  private

  # Returns the 201 response; every other outcome raises.
  def request_lease(http, payload)
    BUSY_ATTEMPTS.times do |attempt|
      response = post(http, payload)
      return response if response.status == 201
      raise crashed("POST /leases answered #{response.status}: #{response.body.to_s.truncate(200)}") \
        if response.status != 503

      ApplyMate::Client::Browser::Clock.sleep_ms(retry_after(response) * 1000) if attempt < BUSY_ATTEMPTS - 1
    end

    raise ApplyMate::Client::Browser::PoolBusy, "browserd pool busy after #{BUSY_ATTEMPTS} attempts"
  end

  # A 201 we cannot read leaves a lease we cannot address; browserd's never-connected rule reaps it
  # within ~75 s.
  def parse_lease(response)
    ApplyMate::Client::Browser::Lease.from_json(JSON.parse(response.body))
  rescue JSON::ParserError, KeyError, TypeError, ArgumentError => e
    raise crashed("POST /leases returned an unreadable lease: #{e.class}")
  end

  def post(http, payload)
    http.post('/leases', payload) { |request| request.options.timeout = LAUNCH_TIMEOUT_S }
  rescue Faraday::Error => e
    raise crashed("POST /leases failed: #{e.class}: #{e.message}")
  end

  def retry_after(response)
    seconds = response.headers['Retry-After'].to_i
    seconds = DEFAULT_RETRY_AFTER_S unless seconds.positive?
    [ seconds, MAX_RETRY_AFTER_S ].min
  end

  def assert_compatible!(lease)
    expected = Playwright::COMPATIBLE_PLAYWRIGHT_VERSION
    return if lease.playwright_version == expected

    ApplyMate::Client::Browser::Operation::ReleaseLease.call(lease:)
    raise ApplyMate::Client::Browser::VersionMismatch,
          "browserd playwright-core #{lease.playwright_version} != playwright-ruby-client #{expected}; " \
          'bump the browserd image and the Gemfile pin together'
  end

  def crashed(message)
    ApplyMate::Client::Browser::Crashed.new("browserd: #{message}")
  end
end
