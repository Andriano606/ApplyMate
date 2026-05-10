# frozen_string_literal: true

require 'async'
require 'resolv'

class Proxy::Operation::ValidateCandidates < ApplyMate::Operation::Base
  include ApplyMate::Logging

  SOCKS_TEST_HOST        = 'www.google.com'
  SOCKS_TEST_PORT        = 443
  VALIDATION_CONCURRENCY = Integer(ENV.fetch('FETCH_PROXIES_VALIDATION_CONCURRENCY', '3000'))
  VALIDATION_TIMEOUT     = 3

  HTTP_PROXY_PROTOCOLS  = %w[http https].freeze
  SOCKS_PROXY_PROTOCOLS = %w[socks4 socks4a socks5 socks5h].freeze

  def perform!(candidates:, **)
    filtered = candidates.uniq { |p| "#{p[:protocol]}:#{p[:host]}:#{p[:port]}" }
                         .select { |p| p[:host].match?(/\A(\d{1,3}\.){3}\d{1,3}\z/) }
                         .shuffle

    source_uris = Source.all.filter_map { |s| URI.parse(s.base_url) rescue nil }

    valid = log_time('Validation') { validate(filtered, source_uris) }
    log('No valid proxies found', level: :warn, color: :red) if valid.empty?

    self.model = valid
  end

  private

  def validate(candidates, source_uris)
    queue  = Async::Queue.new
    valid  = []
    tested = 0

    candidates.each { |c| queue.enqueue(c) }
    VALIDATION_CONCURRENCY.times { queue.enqueue(nil) }

    fiber_width = VALIDATION_CONCURRENCY.to_s.length
    total       = candidates.size
    started_at  = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Pre-resolve hostnames used in SOCKS4 probes BEFORE entering the Async block.
    # Resolv.getaddress is not fiber-aware in the Async scheduler — calling it inside
    # a fiber blocks the entire reactor thread until DNS responds.
    @resolved_ips = ([ SOCKS_TEST_HOST ] + source_uris.map(&:host)).uniq.each_with_object({}) do |h, map|
      map[h] = Resolv.getaddress(h) rescue nil
    end

    # Shared SSL context — set_params loads the CA bundle; reusing it avoids
    # repeated file I/O (which also blocks the reactor) per validated proxy.
    @ssl_ctx = OpenSSL::SSL::SSLContext.new.tap(&:set_params)

    Async do
      workers = VALIDATION_CONCURRENCY.times.map do |idx|
        Async do
          fiber_n = (idx + 1).to_s.rjust(fiber_width)
          loop do
            candidate = queue.dequeue
            break unless candidate

            reachable  = reachable_via_proxy?(candidate) &&
                         source_reachable_via_proxy?(candidate, source_uris)
            tested    += 1

            if reachable
              valid   << candidate
              elapsed  = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
              pct      = (tested * 100.0 / total).round(1)
              log("fiber=#{fiber_n} #{'valid'.ljust(7)} #{candidate[:protocol]}://#{candidate[:host]}:#{candidate[:port]} (valid=#{valid.size} tested=#{tested}/#{total} #{pct}% elapsed=#{elapsed.round(1)}s)", color: :green)
            end
          end
        end
      end

      workers.each(&:wait)
    end

    valid
  end

  def reachable_via_proxy?(candidate)
    case candidate[:protocol]
    when *HTTP_PROXY_PROTOCOLS  then http_proxy_reachable?(candidate)
    when *SOCKS_PROXY_PROTOCOLS then socks_proxy_reachable?(candidate)
    else false
    end
  end

  def source_reachable_via_proxy?(candidate, source_uris)
    source_uris.shuffle.any? { |uri| proxy_fetch_ok?(candidate, uri) }
  end

  # HTTP/HTTPS proxy validation via a plain CONNECT handshake over TCPSocket.
  # TCPSocket.new is fiber-aware under Ruby 3's Async scheduler — no Async::HTTP::Client,
  # no connection pool, no pool-drain warning.
  def http_proxy_reachable?(candidate)
    Async::Task.current.with_timeout(VALIDATION_TIMEOUT) do
      sock = TCPSocket.new(candidate[:host], candidate[:port].to_s)
      begin
        sock.write("CONNECT #{SOCKS_TEST_HOST}:#{SOCKS_TEST_PORT} HTTP/1.1\r\n" \
                   "Host: #{SOCKS_TEST_HOST}:#{SOCKS_TEST_PORT}\r\n\r\n")
        status_line = sock.gets
        status_line&.split(' ', 3)&.at(1).to_i == 200
      ensure
        sock.close rescue nil
      end
    end
  rescue StandardError
    false
  end

  # Pure-fiber SOCKS probe: TCPSocket.new is fiber-aware under Ruby 3's Async scheduler,
  # so all four SOCKS variants run concurrently without threads or Fiber.blocking.
  # We only verify the tunnel handshake reaches SOCKS_TEST_HOST:SOCKS_TEST_PORT — no
  # TLS or HTTP required, which keeps probes fast and avoids TLS cert issues on bad proxies.
  def socks_proxy_reachable?(candidate)
    Async::Task.current.with_timeout(VALIDATION_TIMEOUT) do
      sock = TCPSocket.new(candidate[:host], candidate[:port].to_s)
      begin
        case candidate[:protocol]
        when 'socks5', 'socks5h' then socks5_tunnel_open?(sock)
        when 'socks4a'           then socks4a_tunnel_open?(sock)
        when 'socks4'            then socks4_tunnel_open?(sock)
        else false
        end
      ensure
        sock.close rescue nil
      end
    end
  rescue StandardError
    false
  end

  # Opens a tunnel to host:port through the proxy and performs a real HTTP GET,
  # confirming status 200/3xx and a non-empty body. OpenSSL::SSL::SSLSocket is
  # fiber-safe under Ruby 3's scheduler (uses ssl_{read,write}_nonblock + IO.select).
  def proxy_fetch_ok?(candidate, uri)
    Async::Task.current.with_timeout(VALIDATION_TIMEOUT) do
      host = uri.host
      port = uri.port || (uri.scheme == 'https' ? 443 : 80)
      sock = open_tunnel(candidate, host, port)
      return false unless sock

      ssl = nil
      begin
        if uri.scheme == 'https'
          ssl = OpenSSL::SSL::SSLSocket.new(sock, @ssl_ctx)
          ssl.hostname   = host
          ssl.sync_close = true
          ssl.connect
        end
        io = ssl || sock
        io.write("GET #{uri.path.presence || '/'} HTTP/1.0\r\nHost: #{host}\r\nConnection: close\r\n\r\n")
        raw    = io.read(4096).to_s
        status = raw.split("\r\n", 2).first&.split(' ', 3)&.at(1).to_i
        sep    = raw.index("\r\n\r\n")
        # 3xx redirects have empty bodies but prove the proxy reaches the target site.
        # 2xx require a non-empty body to rule out transparent interception.
        (300..399).cover?(status) || (status == 200 && sep && raw.length > sep + 4)
      rescue StandardError
        false
      ensure
        ssl&.close rescue nil
        sock.close rescue nil
      end
    end
  rescue StandardError
    false
  end

  def open_tunnel(candidate, host, port)
    case candidate[:protocol]
    when *HTTP_PROXY_PROTOCOLS  then http_open_tunnel(candidate, host, port)
    when *SOCKS_PROXY_PROTOCOLS then socks_open_tunnel(candidate, host, port)
    end
  end

  def http_open_tunnel(candidate, host, port)
    sock = TCPSocket.new(candidate[:host], candidate[:port].to_s)
    sock.write("CONNECT #{host}:#{port} HTTP/1.1\r\nHost: #{host}:#{port}\r\n\r\n")
    return sock if sock.gets&.split(' ', 3)&.at(1).to_i == 200
    sock.close rescue nil
    nil
  rescue StandardError
    sock&.close rescue nil
    nil
  end

  def socks_open_tunnel(candidate, host, port)
    sock = TCPSocket.new(candidate[:host], candidate[:port].to_s)
    ok   = case candidate[:protocol]
    when 'socks5', 'socks5h' then socks5_tunnel_open?(sock, host, port)
    when 'socks4a'           then socks4a_tunnel_open?(sock, host, port)
    when 'socks4'            then socks4_tunnel_open?(sock, host, port)
    else false
    end
    return sock if ok
    sock.close rescue nil
    nil
  rescue StandardError
    sock&.close rescue nil
    nil
  end

  # SOCKS5 RFC 1928: no-auth negotiation then CONNECT by domain name.
  def socks5_tunnel_open?(sock, host = SOCKS_TEST_HOST, port = SOCKS_TEST_PORT)
    sock.write("\x05\x01\x00")
    return false unless sock.read(2) == "\x05\x00"

    host_b  = host.b
    request = [ 0x05, 0x01, 0x00, 0x03, host_b.bytesize ].pack('C5') +
              host_b +
              [ port ].pack('n')
    sock.write(request)

    head = sock.read(4)
    return false unless head&.length == 4 && head.getbyte(0) == 0x05 && head.getbyte(1) == 0x00

    # Consume bound-address so the socket is left clean.
    case head.getbyte(3)
    when 0x01 then sock.read(6)                      # IPv4 (4) + port (2)
    when 0x03 then sock.read(sock.read(1).ord + 2)   # 1-byte len + domain + port (2)
    when 0x04 then sock.read(18)                     # IPv6 (16) + port (2)
    end

    true
  rescue StandardError
    false
  end

  # SOCKS4a: IP=0.0.0.1 signals that a null-terminated hostname follows the userid field.
  def socks4a_tunnel_open?(sock, host = SOCKS_TEST_HOST, port = SOCKS_TEST_PORT)
    request = "\x04\x01" +
              [ port ].pack('n') +
              "\x00\x00\x00\x01" +   # special IP → proxy resolves hostname
              "\x00" +                # empty userid
              host +
              "\x00"
    sock.write(request)

    reply = sock.read(8)
    reply&.length == 8 && reply.getbyte(0) == 0x00 && reply.getbyte(1) == 0x5a
  rescue StandardError
    false
  end

  # SOCKS4: must send a resolved IPv4 address. IP is looked up from @resolved_ips
  # (pre-resolved before the Async block) to avoid blocking the reactor thread.
  def socks4_tunnel_open?(sock, host = SOCKS_TEST_HOST, port = SOCKS_TEST_PORT)
    ip_str   = @resolved_ips&.fetch(host, nil) || Resolv.getaddress(host)
    ip_bytes = ip_str.split('.').map(&:to_i).pack('C4')
    request  = "\x04\x01" + [ port ].pack('n') + ip_bytes + "\x00"
    sock.write(request)

    reply = sock.read(8)
    reply&.length == 8 && reply.getbyte(0) == 0x00 && reply.getbyte(1) == 0x5a
  rescue StandardError
    false
  end
end
