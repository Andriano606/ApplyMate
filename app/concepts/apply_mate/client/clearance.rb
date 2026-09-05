# frozen_string_literal: true

# Cloudflare clearance for sources behind a *managed* challenge — the interstitial
# that has to run JS ("Just a moment…"), not the passive TLS-fingerprint check that
# ImpersonateHttp already defeats.
#
# Measured against rubyonremote.com: AsyncHttp and ImpersonateHttp both get 403 on
# every URL (listing, sitemap, feed), and so does every browser we DRIVE — Ferrum and
# Playwright, headless and headful, real Chrome, genuine or spoofed UA, warm profile
# or cold. An attached CDP session is itself the tell: the token gets issued and
# immediately re-challenged. A Chrome nobody is attached to clears the same page in
# ~6 seconds.
#
# So the browser is used for exactly one thing: earning the `cf_clearance` cookie,
# unattached, watched only through the debugging port's JSON endpoint (plain HTTP —
# it opens no session). The cookie, plus the User-Agent that earned it, then ride as
# ordinary headers on ordinary requests, which Cloudflare accepts: one Chrome per
# host per CACHE_TTL, every scrape after it at HTTP speed.
#
#   headers = ApplyMate::Client::Clearance.headers(url)
#   client.get(url, headers: headers)
#
# The token is issued to an identity, not just to a browser: it stops working the
# moment the User-Agent stops matching (measured — the same token returns 200 with
# the warming Chrome's UA and 403 with curl's). Callers must therefore send BOTH
# headers this returns, never just the cookie. `--headless` is not usable (measured:
# never clears), so the host needs a display — Xvfb is enough, and clears just as
# fast as a real one.
class ApplyMate::Client::Clearance
  # Raised when the challenge did not clear: this IP cannot read the site right now.
  class ChallengeError < StandardError; end

  # Raised when the host cannot run the warm-up at all (no Chrome, no display, no
  # free profile). Distinct from ChallengeError on purpose — one means "this site
  # refused us", the other "this machine is misconfigured", and they call for
  # opposite reactions from the caller.
  class BrowserError < StandardError; end

  # Cloudflare issues cf_clearance for longer than this, but the exact lifetime is
  # the site's setting and is not in the cookie we can rely on. Re-warming a few
  # minutes early costs one Chrome launch; using a dead token costs a whole sync run.
  CACHE_TTL = 20.minutes

  # The challenge itself takes seconds (6 measured, twice). This budget is for a slow
  # or rate-limited exit IP, and it is what stops the poll loop when the site simply
  # never lets this address through.
  CLEAR_TIMEOUT  = 60
  POLL_INTERVAL  = 1

  # The debugging port is picked here rather than with `--remote-debugging-port=0`,
  # which would be the obvious way to avoid collisions: measured, a Chrome started on
  # port 0 never clears the challenge, while the same Chrome on a fixed port clears it
  # in four seconds. Whatever Cloudflare reads to tell them apart, an ephemeral port
  # is not worth the outage.
  PORT_TIMEOUT   = 20

  # A slot from the driven browser's pool, taken for its lock rather than its
  # contents: it caps concurrent warm-ups at the pool size (an unbounded fan-out of
  # Chromes is what a 4-core host cannot survive) and keeps two of them off one
  # directory. The profile itself is thrown away every time — see SESSION_DIR.
  PROFILE_WAIT   = 45

  # Chrome runs in this subdirectory of the slot, wiped before every warm-up.
  #
  # A reused profile is what a persistent browser wants and the opposite of what this
  # needs: measured, a profile that has already failed the challenge never clears it
  # again (Cloudflare keeps re-challenging the state it left behind), while a fresh
  # directory on the same host and IP clears in seconds. The slot's lock file lives
  # beside it and must survive, hence a subdirectory rather than the slot itself.
  SESSION_DIR    = 'session'

  # How long Chrome gets to exit on TERM before it is killed outright.
  TERMINATE_TIMEOUT = 5

  class << self
    # Headers that get an ordinary HTTP client past the challenge, or {} if this
    # host is not the kind that needs one. Cached per (host, proxy) — a token is
    # bound to the address that earned it, so a proxied client must not reuse the
    # one warmed for another exit IP.
    def headers(url, proxy: nil)
      origin = origin_of(url)
      return {} if origin.nil?

      cached = Rails.cache.read(cache_key(origin.host, proxy))
      return cached if cached.present?

      warm(origin, proxy: proxy)
    end

    # Drops the cached token — for a caller that has just been refused with it and
    # wants the next attempt to earn a fresh one instead of replaying a dead one.
    def forget(url, proxy: nil)
      origin = origin_of(url)
      Rails.cache.delete(cache_key(origin.host, proxy)) if origin
    end

    private

    # The site's root, kept whole (scheme and port included) because that is what the
    # browser is pointed at; the challenge is served from the origin, not from the
    # deep link that happened to trigger the warm-up.
    def origin_of(url)
      uri = URI.parse(url.to_s)
      return nil if uri.host.blank?

      uri.dup.tap do |origin|
        origin.path  = '/'
        origin.query = nil
        origin.fragment = nil
      end
    rescue URI::InvalidURIError
      nil
    end

    def cache_key(host, proxy)
      [ 'clearance', host, proxy.presence || 'direct' ].join('/')
    end

    def warm(origin, proxy:)
      new(origin, proxy: proxy).call.tap do |headers|
        Rails.cache.write(cache_key(origin.host, proxy), headers, expires_in: CACHE_TTL)
      end
    end
  end

  def initialize(origin, proxy: nil)
    @origin = URI.parse(origin.to_s)
    @host   = @origin.host
    @proxy  = proxy
  end

  # Launches Chrome on the site, waits for the challenge to clear, and returns the
  # headers that inherit its clearance. Raises rather than returning {}: a caller
  # that fetched without them would read a challenge page and mistake it for an
  # empty listing.
  def call
    profile = acquire_profile
    pid     = nil
    session = nil
    begin
      session = fresh_session_dir(profile)
      port    = free_port
      pid     = spawn_chrome(session, port)
      wait_until_listening(port)
      wait_for_clearance(port)
      collect_headers(port)
    ensure
      # Inside the begin, all of it: a slot released only on the happy path would be
      # held for the life of the process, and the pool is four deep.
      terminate(pid)
      FileUtils.rm_rf(session) if session
      profile.release
    end
  end

  private

  # Emptied rather than reused, for the reason SESSION_DIR gives.
  def fresh_session_dir(profile)
    path = File.join(profile.path, SESSION_DIR)
    FileUtils.rm_rf(path)
    FileUtils.mkdir_p(path)
    path
  end

  def acquire_profile
    deadline = monotonic + PROFILE_WAIT
    loop do
      slot = ApplyMate::Client::BrowserProfile.acquire("clearance-#{@host}")
      return slot if slot
      raise BrowserError, "no free browser profile for #{@host}" if monotonic >= deadline

      sleep POLL_INTERVAL
    end
  end

  # Not headless: `--headless=new` never clears the challenge (measured, 75s), while
  # the same Chrome on a display clears in 6 — including a virtual one, so a server
  # needs Xvfb rather than a screen. And no CDP client may attach before the
  # challenge is solved, so this is a bare spawn, not Ferrum.
  def spawn_chrome(profile_path, port)
    binary = ApplyMate::Client::Browser.chrome_path
    raise BrowserError, 'no Chrome binary on this host (set CHROME_PATH)' if binary.blank?

    Process.spawn(binary, *chrome_arguments(profile_path, port),
                  out: File::NULL, err: File::NULL, pgroup: true)
  rescue Errno::ENOENT => e
    raise BrowserError, "could not launch Chrome: #{e.message}"
  end

  def chrome_arguments(profile_path, port)
    [
      "--user-data-dir=#{profile_path}",
      "--remote-debugging-port=#{port}",
      '--no-first-run',
      '--no-default-browser-check',
      proxy_argument,
      @origin.to_s
    ].compact
  end

  # A port free at this instant. Racy in principle — nothing holds it between here
  # and Chrome binding it — but the alternative (port 0) does not clear challenges,
  # and a collision merely fails one warm-up.
  def free_port
    server = TCPServer.new('127.0.0.1', 0)
    server.addr[1]
  ensure
    server&.close
  end

  # Chrome takes the proxy as one flag for every scheme; the token then belongs to
  # that exit IP, which is why the cache key carries the proxy too.
  def proxy_argument
    @proxy.present? ? "--proxy-server=#{@proxy}" : nil
  end

  # Readiness is asked of the port itself rather than of Chrome's DevToolsActivePort
  # file, which it does not always write. /json/version is plain HTTP and attaches no
  # debugger — the thing that must not happen before the challenge is solved.
  def wait_until_listening(port)
    deadline = monotonic + PORT_TIMEOUT
    until devtools(port, '/json/version')
      raise BrowserError, 'Chrome did not open its debugging port (no display?)' if monotonic >= deadline

      sleep POLL_INTERVAL
    end
  end

  # Watched through the debugging port's HTTP JSON rather than a CDP session: reading
  # /json/list creates no session, and a session is the one thing that keeps the
  # challenge from ever clearing.
  def wait_for_clearance(port)
    deadline = monotonic + CLEAR_TIMEOUT
    loop do
      return if page_titles(port).any? { |title| title.present? && !challenge?(title) }

      raise ChallengeError, "#{@host} did not clear its challenge in #{CLEAR_TIMEOUT}s" if monotonic >= deadline

      sleep POLL_INTERVAL
    end
  end

  def page_titles(port)
    JSON.parse(devtools(port, '/json/list').to_s)
        .select { |target| target['type'] == 'page' && target['url'].to_s.include?(@host) }
        .map { |target| target['title'].to_s }
  rescue StandardError
    []
  end

  # Reads one of Chrome's DevTools HTTP endpoints, or nil while it is not up yet.
  #
  # Host: localhost is not decoration — Chrome refuses any DevTools HTTP request whose
  # Host header is a bare IP (its defence against DNS rebinding), and Net::HTTP would
  # otherwise fill in "127.0.0.1:<port>" and every poll would come back 500.
  def devtools(port, path)
    response = Net::HTTP.start('127.0.0.1', port, open_timeout: POLL_INTERVAL, read_timeout: POLL_INTERVAL) do |http|
      http.request(Net::HTTP::Get.new(path, 'Host' => 'localhost'))
    end
    response.body if response.is_a?(Net::HTTPSuccess)
  rescue StandardError
    nil
  end

  def challenge?(title)
    ApplyMate::Client::Response::CLOUDFLARE_MARKERS.any? { |marker| title.include?(marker) }
  end

  # Safe to attach now: the clearance is already earned, and it is the cookie jar and
  # the real User-Agent we need out of the browser before it dies.
  def collect_headers(port)
    browser = Ferrum::Browser.new(url: "http://127.0.0.1:#{port}")
    page    = browser.pages.find { |candidate| candidate.url.to_s.include?(@host) }
    raise ChallengeError, "no #{@host} page left to read the clearance from" if page.nil?

    token = page.cookies.all['cf_clearance']&.value
    raise ChallengeError, "#{@host} granted no cf_clearance" if token.blank?

    { 'Cookie' => "cf_clearance=#{token}", 'User-Agent' => page.evaluate('navigator.userAgent').to_s }
  rescue Ferrum::Error => e
    raise ChallengeError, "could not read the clearance: #{e.message}"
  end

  # Chrome spawns a tree of processes (zygotes, renderers); killing the group is what
  # actually frees the profile lock the next warm-up needs. KILL follows TERM because
  # a Chrome stuck on shutdown would otherwise hold that lock for the rest of the run.
  def terminate(pid)
    return if pid.nil?

    Process.kill('TERM', -pid)
    deadline = monotonic + TERMINATE_TIMEOUT
    until monotonic >= deadline
      return if Process.waitpid(pid, Process::WNOHANG)

      sleep 0.2
    end

    Process.kill('KILL', -pid)
    Process.waitpid(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
