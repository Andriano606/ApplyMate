# Port of the attached runtime's createNetTracker: watches one page's network (all its frames and origins).
#
# Events arrive on playwright-ruby-client's reader thread, so all state is in concurrent collections and the
# callbacks never call back into Playwright (a blocking server call from the reader thread would deadlock it) and
# never raise (an exception there would kill the connection's dispatch loop).
#
# - In-flight requests (every method) feed #pending / #last_event_at, which Operation::WaitQuiet polls.
# - Every finished or failed non-GET request whose host is not in IGNORED_HOSTS is recorded as
#   { url:, method:, status:, at:, frame_url: } (status nil when it failed; at = monotonic ms when it started).
#   #mark / #since(mark) return what an action caused. At most MAX_RECORDS are kept, oldest dropped.
class ApplyMate::Client::Browser::NetTracker
  MAX_RECORDS = 500
  IGNORE_OLDER_MS = 3_000
  STALE_MS = 60_000

  # Analytics, telemetry and captcha traffic: never evidence of a submit. 'host/path' entries match a path prefix.
  IGNORED_HOSTS = %w[
    google-analytics.com googletagmanager.com doubleclick.net recaptcha.net gstatic.com/recaptcha
    google.com/recaptcha hcaptcha.com challenges.cloudflare.com sentry.io segment.io hotjar.com facebook.net
  ].map { |entry| entry.split('/', 2) }.freeze

  def initialize(page)
    @page = page
    @inflight = Concurrent::Map.new
    @records = Concurrent::Array.new
    @last_event_at = Concurrent::AtomicReference.new(-Float::INFINITY)
    @handlers = {
      'request' => ->(request) { on_request(request) },
      'requestfinished' => ->(request) { on_done(request) },
      'requestfailed' => ->(request) { on_done(request) }
    }
    @handlers.each { |event, handler| page.on(event, handler) }
  end

  # Requests in flight that started less than ignore_older_ms ago (long-polls, SSE and beacons older than that must
  # not block an action). Ignored entries older than STALE_MS are dropped for good (hung requests).
  def pending(ignore_older_ms: IGNORE_OLDER_MS)
    now = clock.now_ms
    count = 0
    @inflight.each_pair do |request, started_at|
      age = now - started_at
      if age < ignore_older_ms
        count += 1
      elsif age > STALE_MS
        @inflight.delete(request)
      end
    end
    count
  end

  def last_event_at
    @last_event_at.get
  end

  def mark
    clock.now_ms
  end

  def since(mark)
    @records.select { |record| record[:at] >= mark }
  end

  def dispose
    @handlers.each { |event, handler| @page.off(event, handler) }
    @inflight.clear
  rescue StandardError
    @inflight.clear # the connection may already be gone; the listeners die with it
  end

  private

  def on_request(request)
    now = clock.now_ms
    @inflight[request] = now
    @last_event_at.set(now)
  rescue StandardError
    nil
  end

  def on_done(request)
    started_at = @inflight.delete(request)
    @last_event_at.set(clock.now_ms)
    record(request, started_at) if request.method != 'GET' && !ignored?(request.url)
  rescue StandardError
    nil
  end

  def record(request, started_at)
    @records << { url: request.url, method: request.method, status: request.existing_response&.status,
                  at: started_at || clock.now_ms, frame_url: frame_url(request) }
    @records.shift while @records.size > MAX_RECORDS
  end

  def ignored?(url)
    uri = URI.parse(url)
    host = uri.host.to_s.downcase
    IGNORED_HOSTS.any? do |ignored_host, path|
      (host == ignored_host || host.end_with?(".#{ignored_host}")) && (path.nil? || uri.path.start_with?("/#{path}"))
    end
  rescue URI::InvalidURIError
    false
  end

  def frame_url(request)
    request.frame.url
  rescue StandardError
    nil
  end

  def clock
    ApplyMate::Client::Browser::Clock
  end
end
