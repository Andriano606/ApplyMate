# Port of the attached runtime's createNetTracker: watches one page's network (all its frames and origins).
#
# Events arrive on playwright-ruby-client's reader thread, so all state is in concurrent collections and the
# callbacks never call back into Playwright (a blocking server call from the reader thread would deadlock it) and
# never raise (an exception there would kill the connection's dispatch loop).
#
# - In-flight requests (every method) feed #pending / #last_event_at, which Operation::WaitQuiet polls.
# - Every finished or failed non-GET request whose host is not in IGNORED_HOSTS is recorded as
#   { url:, method:, status:, at:, frame_url:, body: } (status nil when it failed; at = monotonic ms when it
#   started). #mark / #since(mark) return what an action caused; #in_flight_since(mark) counts the non-GET requests
#   it started that have not ended yet. At most MAX_RECORDS are kept, oldest dropped.
#   Request bodies are never stored (they carry the applicant's answers).
# - Response bodies: only for finished requests whose URL matches a pattern registered with #watch (the platform's
#   success_evidence[:submit_request]). Reading a body is a Playwright call, so the reader thread only POSTS the
#   read to a per-tracker executor (one thread, at most BODY_QUEUE waiting reads; more are dropped with body nil) and
#   the read runs there, eagerly, while the response is still held by the browser. #since(mark, bodies: true) waits
#   on the caller thread for those reads, BODY_WAIT_MS in total, and returns the first BODY_CAP bytes (nil when the
#   read failed, was dropped or did not finish in time). With bodies: false (default) `body` is always nil.
class ApplyMate::Client::Browser::NetTracker
  MAX_RECORDS = 500
  IGNORE_OLDER_MS = 3_000
  STALE_MS = 60_000
  BODY_CAP = 64.kilobytes
  BODY_QUEUE = 8
  BODY_WAIT_MS = 5_000

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
    @watched = Concurrent::Array.new
    @body_reader = Concurrent::ThreadPoolExecutor.new(min_threads: 0, max_threads: 1, max_queue: BODY_QUEUE,
                                                      fallback_policy: :abort)
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

  # Non-GET requests outside IGNORED_HOSTS that started at or after `mark` and have neither finished nor failed yet
  # (#since does not list them: a request is recorded when it ends). No age cut-off of its own: a submit still in
  # flight when VerifySubmit asks must count however long it has been running. Only #pending evicts entries (older
  # than STALE_MS); the submit settle + verify wait end well within that.
  def in_flight_since(mark)
    count = 0
    @inflight.each_pair do |request, started_at|
      count += 1 if started_at >= mark && request.method != 'GET' && !ignored?(request.url)
    end
    count
  end

  def last_event_at
    @last_event_at.get
  end

  def mark
    clock.now_ms
  end

  def since(mark, bodies: false)
    wait_until = clock.now_ms + BODY_WAIT_MS
    @records.select { |record| record[:at] >= mark }.map do |record|
      record.merge(body: bodies ? body_of(record[:body], wait_until) : nil)
    end
  end

  # Capture the response body of finished non-GET requests whose URL matches `pattern` (a Regexp).
  def watch(pattern)
    raise ArgumentError, "watch expects a Regexp, got #{pattern.class}" unless pattern.is_a?(Regexp)

    @watched << pattern unless @watched.include?(pattern)
    self
  end

  def dispose
    @body_reader.shutdown
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
    status = request.existing_response&.status
    @records << { url: request.url, method: request.method, status:, at: started_at || clock.now_ms,
                  frame_url: frame_url(request), body: status && watched?(request.url) ? read_later(request) : nil }
    @records.shift while @records.size > MAX_RECORDS
  end

  def watched?(url)
    @watched.any? { |pattern| pattern.match?(url) }
  end

  # Runs on the reader thread: only enqueues. A full queue (or a shut-down executor) means no body, never a block.
  def read_later(request)
    Concurrent::Promises.future_on(@body_reader, request) { |watched| read_body(watched) }
  rescue Concurrent::RejectedExecutionError
    nil
  end

  # Runs on the body reader thread, never on the reader thread.
  def read_body(request)
    body = request.response&.body
    body&.byteslice(0, BODY_CAP)&.force_encoding(Encoding::UTF_8)&.scrub
  rescue StandardError
    nil
  end

  def body_of(future, wait_until)
    return if future.nil?

    future.value([ wait_until - clock.now_ms, 0 ].max / 1000.0)
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
