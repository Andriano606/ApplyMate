# frozen_string_literal: true

require 'open3'
require 'tempfile'

# The HTTP client of every scraper: shells out to curl-impersonate so each request carries
# a real browser's TLS + HTTP/2 fingerprint. Cloudflare-protected sites (Dou) reject an
# OpenSSL fingerprint regardless of headers; curl-impersonate (BoringSSL + the browser's
# cipher/extension order + HTTP/2 settings) passes the non-interactive challenge without a
# browser, at HTTP speed. ProxyMate checks every proxy with this very tool, so "working for
# <site>" in ProxyMate means "working through curl-impersonate" — the reason every source
# uses this client.
#
# The curl-impersonate binary is arch-specific and NOT committed. Install it with
# `bin/install-curl-impersonate` (downloads the pinned RELEASE into vendor/, gitignored)
# or point CURL_IMPERSONATE_BIN at the `curl-impersonate` binary on the host.
#
# A proxy handed out by ProxyMate with a Cloudflare clearance (`clearance:`) is driven with
# that clearance's curl-impersonate target, User-Agent and cf_clearance cookie — Cloudflare
# binds the token to all three plus the proxy IP.
#
# Fan-out: every request is one curl subprocess (~10 MB RSS, a fork+exec and a TLS
# handshake), so at most MAX_PROCESSES of them run at once in the whole process, whatever
# the number of fibers/sources asking. The wait for a slot yields to the Async reactor.
class ApplyMate::Client::ImpersonateHttp
  Response = Struct.new(:body, :headers, :status, :final_url)

  # curl exited non-zero: no HTTP response (refused, timeout, tunnel, TLS…). The message
  # carries curl's exit code and error text.
  RequestError = Class.new(StandardError)

  # The binary itself cannot be started (missing / not executable): a host problem, not the
  # proxy's — scrapers let it through instead of turning it into DeadProxyError.
  BinaryError = Class.new(StandardError)

  # CURL_IMPERSONATE_BIN — path to the `curl-impersonate` binary itself, not a curl_chrome*
  # wrapper: the browser target is picked per request with --impersonate. Defaults to the
  # copy bin/install-curl-impersonate puts into vendor/.
  BINARY = ENV.fetch('CURL_IMPERSONATE_BIN') do
    Rails.root.join('vendor/curl-impersonate/curl-impersonate').to_s
  end

  # The curl-impersonate release bin/install-curl-impersonate pins (its VERSION default) —
  # read from the script so the pin lives in one place. The sync compares it with
  # ProxyMate's GET /api/v1/meta release to know whether ProxyMate's targets run here.
  INSTALLER = Rails.root.join('bin/install-curl-impersonate')
  RELEASE   = INSTALLER.read[/CURL_IMPERSONATE_VERSION:-(v[\d.]+)\}/, 1] ||
              raise("#{INSTALLER} has no CURL_IMPERSONATE_VERSION default — cannot tell the pinned release")

  # CURL_IMPERSONATE_MAX_PROCESSES — concurrent curl subprocesses per Ruby process (default
  # 64: the sync runs WORKERS_PER_SOURCE / DESCRIPTION_WORKERS = 32 fibers per source and
  # two sources at once; 64 × ~10 MB and their handshakes fit a 4-core Raspberry Pi 5).
  # Lower it on a smaller host; more fibers than slots just queue for one.
  MAX_PROCESSES = Integer(ENV.fetch('CURL_IMPERSONATE_MAX_PROCESSES', '64'))
  # Token queue, not Async::Semaphore: Thread::Queue#pop yields to the fiber scheduler inside
  # a reactor and blocks plainly outside one, and is shared safely by all threads.
  SLOTS = Thread::Queue.new.tap { |queue| MAX_PROCESSES.times { queue << true } }

  # The target ProxyMate checks proxies with (ProxyMate::Client::CurlImpersonate::IMPERSONATE),
  # so a proxy it reports working was proven with this very TLS/HTTP2 fingerprint. --impersonate
  # also sets that browser's default headers (User-Agent, Accept, sec-ch-ua, …).
  DEFAULT_IMPERSONATE = 'chrome146'
  # Every protocol ProxyMate hands out — curl implements each natively (see #proxy_arg).
  SUPPORTED_PROXY_PROTOCOLS = %w[http socks4 socks4a socks5 socks5h].freeze

  DEFAULT_REQUEST_TIMEOUT = 15
  DEFAULT_CONNECT_TIMEOUT = 5

  # -w output, one value per line; errormsg last (free text). url_effective is the URL after
  # -L redirects — Djinni's last-page signal is a redirect back to /jobs/.
  WRITE_OUT = "%{http_code}\n%{exitcode}\n%{url_effective}\n%{errormsg}"

  def self.supported_proxy_protocols
    SUPPORTED_PROXY_PROTOCOLS
  end

  # A cf_clearance cookie is replayed with the User-Agent and target it was obtained with.
  def self.supports_cloudflare_clearance?
    true
  end

  # clearance: an ApplyMate::Client::ProxyMate::Clearance (cookie, user_agent, impersonate) or nil.
  def initialize(proxy: nil, request_timeout: DEFAULT_REQUEST_TIMEOUT, connect_timeout: DEFAULT_CONNECT_TIMEOUT, clearance: nil)
    @proxy           = proxy
    @request_timeout = request_timeout
    @connect_timeout = connect_timeout
    @clearance       = clearance
  end

  def get(url, headers: {})
    run(url, headers: headers)
  end

  def post(url, body:, headers: {})
    run(url, method: 'POST', body: body, headers: headers)
  end

  private

  def run(url, method: 'GET', body: nil, headers: {})
    body_file = Tempfile.new('ci_body')
    hdr_file  = Tempfile.new('ci_hdr')
    req_file  = write_request_body(body)
    begin
      stdout, stderr, status = with_process_slot { Open3.capture3(*command(url, method, req_file&.path, headers, body_file, hdr_file)) }
      code, exitcode, final_url, errormsg = stdout.to_s.split("\n", 4)
      # No write-out means curl never got to the request: a rejected option, a binary that
      # cannot start, or a process killed mid-transfer (its body may be truncated). None of
      # that is the proxy's fault — never let it read as a 0-status page or a dead proxy.
      unless exitcode.to_s.match?(/\A\d+\z/)
        raise BinaryError, "#{BINARY} produced no result (exit #{status&.exitstatus.inspect}, " \
                           "signal #{status&.termsig.inspect}): #{stderr.to_s.strip.truncate(300)}"
      end
      raise RequestError, "curl-impersonate failed (exit #{exitcode}): #{errormsg.to_s.strip}" unless exitcode.to_i.zero?

      Response.new(File.read(body_file.path), parse_headers(File.read(hdr_file.path)), code.to_i, final_url.presence || url)
    ensure
      body_file.close!
      hdr_file.close!
      req_file&.close!
    end
  end

  def with_process_slot
    SLOTS.pop
    begin
      yield
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOEXEC => e
      raise BinaryError, "cannot run #{BINARY} (#{e.class}: #{e.message}) — run bin/install-curl-impersonate"
    ensure
      SLOTS << true
    end
  end

  # The request body goes through a file, not argv: a large body would blow past
  # ARG_MAX (and lose NUL bytes) as a command argument.
  def write_request_body(body)
    return nil if body.nil?

    file = Tempfile.new('ci_req')
    file.binmode
    file.write(body)
    file.flush
    file
  end

  def command(url, method, body_path, headers, body_file, hdr_file)
    args = [ BINARY, '--impersonate', @clearance&.impersonate || DEFAULT_IMPERSONATE, '--compressed',
             '-sS', '-L', '-o', body_file.path, '-D', hdr_file.path, '-w', WRITE_OUT,
             '--max-time', @request_timeout.to_s, '--connect-timeout', @connect_timeout.to_s ]
    if (proxy = proxy_arg)
      args.push('--proxy', proxy)
    end
    if method == 'POST'
      args.push('-X', 'POST')
      args.push('--data-binary', "@#{body_path}") if body_path
    end
    with_clearance(headers).each { |key, value| args.push('-H', "#{key}: #{value}") }
    args << url
    args
  end

  # The clearance's User-Agent replaces the impersonated browser's, and its cookie is appended
  # to the Cookie the scraper sends (Dou's csrftoken) — one Cookie header, not two.
  def with_clearance(headers)
    return headers unless @clearance

    cookie = headers.find { |key, _| key.to_s.casecmp?('cookie') }&.last
    headers.reject { |key, _| %w[cookie user-agent].include?(key.to_s.downcase) }
           .merge('User-Agent' => @clearance.user_agent, 'Cookie' => [ cookie, @clearance.cookie ].compact_blank.join('; '))
  end

  # socks5:// → socks5h:// so DNS resolves through the proxy (datacenter proxies often can't
  # be reached for local DNS of the target). http://, socks4:// (curl resolves locally — the
  # protocol carries only an IPv4), socks4a:// and socks5h:// (remote DNS) pass through.
  def proxy_arg
    return nil if @proxy.blank?

    uri = URI.parse(@proxy.to_s)
    uri.scheme.to_s.casecmp?('socks5') ? "socks5h://#{uri.host}:#{uri.port}" : @proxy.to_s
  end

  # curl -D dumps every header block (proxy CONNECT, redirects, final response): lowercase
  # keys, Set-Cookie collected into an Array (Django + Cloudflare emit several), everything
  # else last-wins (= the final response's value).
  def parse_headers(raw)
    raw.to_s.each_line.each_with_object({}) do |line, headers|
      key, value = line.chomp.split(':', 2)
      next if value.nil?

      k = key.strip.downcase
      v = value.strip
      if k == 'set-cookie'
        (headers[k] ||= []) << v
      else
        headers[k] = v
      end
    end
  end
end
