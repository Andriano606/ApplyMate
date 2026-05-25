# frozen_string_literal: true

require 'async'
require 'kernel/sync'
require 'resolv'

# Unified HTTP client: raw fiber-aware sockets, optional proxy (HTTP CONNECT,
# SOCKS5, or direct). Works both inside an Async fiber and outside one
# (wraps the call in Sync { … } so SolidQueue jobs can use the same client).
# All retry / error policy is delegated to the injected ErrorHandler.
class ApplyMate::Client::AsyncHttp < ApplyMate::Client::Base
  MAX_REDIRECTS    = 5
  CONNECT_TIMEOUT  = 5
  HTTP_PROTOCOLS   = %w[http https].freeze
  SOCKS5_PROTOCOLS = %w[socks5 socks5h].freeze
  PROXY_DEAD_STATUSES = [ 502, 503, 504 ].freeze

  # Errors that mean "the underlying TCP/TLS connection failed" — caller should treat
  # them as a dead proxy, not as a bug. Anything outside this list propagates so real
  # bugs are visible in logs instead of being silently converted to proxy failures.
  NETWORK_ERRORS = [
    Async::TimeoutError, IOError, EOFError, SocketError,
    Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT,
    Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EPIPE,
    OpenSSL::SSL::SSLError
  ].freeze

  # `Socket.tcp` calls C-level `getaddrinfo(3)` which the Fiber Scheduler cannot
  # intercept — it blocks the whole reactor thread. Pre-resolving via pure-Ruby
  # `Resolv` makes DNS fiber-aware; caching avoids repeat lookups for the same host.
  DNS_CACHE = Concurrent::Map.new
  DNS_TTL_S = 300

  def initialize(timeout: 15, proxy: nil, error_handler: nil)
    @timeout       = timeout
    @proxy_uri     = proxy.present? ? URI.parse(proxy) : nil
    @ssl_ctx       = OpenSSL::SSL::SSLContext.new.tap(&:set_params)
    @error_handler = error_handler || self.class.default_error_handler
  end

  def self.resolve(host)
    return host if host.nil? || host.empty?
    return host if host.match?(/\A\d{1,3}(\.\d{1,3}){3}\z/) || host.include?(':')

    entry = DNS_CACHE[host]
    now   = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return entry[:ip] if entry && entry[:expires_at] > now

    ip = Resolv.getaddress(host)
    DNS_CACHE[host] = { ip: ip, expires_at: now + DNS_TTL_S }
    ip
  rescue Resolv::ResolvError, Resolv::ResolvTimeout
    host
  end

  def get(url, headers: {}, follow_redirects: true, **)
    @error_handler.run { perform(:GET, url, headers: headers, follow_redirects: follow_redirects) }
  end

  def post(url, body:, headers: {}, **)
    @error_handler.run { perform(:POST, url, body: body, headers: headers, follow_redirects: true) }
  end

  # Sends a multipart POST without redirect-following — the caller inspects
  # 3xx responses directly (e.g. to detect a successful form submission).
  def post_multipart(url, payload:, headers: {})
    body, content_type = build_multipart(payload)
    extra_headers      = headers.merge('Content-Type' => content_type)
    @error_handler.run { perform(:POST, url, body: body, headers: extra_headers, follow_redirects: false) }
  end

  private

  def perform(method, url, headers:, body: nil, follow_redirects:)
    full_headers = self.class.merge_default_headers(headers)
    response     = with_timeout { request_with_redirects(method, url, full_headers, body, MAX_REDIRECTS, follow_redirects) }
    raise DeadProxyError, "Connection failed for #{url} (proxy=#{@proxy_uri})" if response.nil?
    if @proxy_uri && PROXY_DEAD_STATUSES.include?(response.status)
      raise DeadProxyError, "HTTP #{response.status} via proxy=#{@proxy_uri}"
    end

    response
  end

  def request_with_redirects(method, url, headers, body, remaining, follow_redirects)
    response = send_once(method, url, headers, body)
    return nil if response.nil?

    if follow_redirects && (300..399).cover?(response.status) && remaining.positive?
      location = response.headers['location']
      if location.present?
        new_url    = URI.join(url, location).to_s
        # 307/308 preserve method+body; all others switch to GET (standard browser behaviour)
        new_method = [ 307, 308 ].include?(response.status) ? method : :GET
        new_body   = new_method == :GET ? nil : body
        return request_with_redirects(new_method, new_url, headers, new_body, remaining - 1, follow_redirects)
      end
    end

    response.final_url = url
    response
  end

  def send_once(method, url, headers, body)
    uri  = URI.parse(url)
    port = uri.port || (uri.scheme == 'https' ? 443 : 80)
    sock = open_tunnel(uri.host, port)
    return nil unless sock

    io  = sock
    ssl = nil
    begin
      if uri.scheme == 'https'
        ssl = OpenSSL::SSL::SSLSocket.new(sock, @ssl_ctx)
        ssl.hostname   = uri.host
        ssl.sync_close = true
        return nil unless ssl_connect(ssl)
        io  = ssl
        ssl = nil
      end

      write_request(io, method, uri, headers, body)
      read_response(io)
    rescue *NETWORK_ERRORS
      nil
    ensure
      io.close   rescue nil
      ssl&.close rescue nil
    end
  end

  def with_timeout(&block)
    if Async::Task.current?
      Async::Task.current.with_timeout(@timeout, &block)
    else
      Sync { Async::Task.current.with_timeout(@timeout, &block) }
    end
  rescue *NETWORK_ERRORS
    nil
  end

  def open_tunnel(host, port)
    target_ip = self.class.resolve(host)
    return Socket.tcp(target_ip, port.to_i, connect_timeout: CONNECT_TIMEOUT) if @proxy_uri.nil?

    proxy_ip = self.class.resolve(@proxy_uri.host)
    sock     = Socket.tcp(proxy_ip, @proxy_uri.port.to_i, connect_timeout: CONNECT_TIMEOUT)
    return nil unless sock

    case @proxy_uri.scheme.to_s.downcase
    when *HTTP_PROTOCOLS   then http_connect_tunnel(sock, host, port)
    when *SOCKS5_PROTOCOLS then socks5_tunnel(sock, host, port)
    else
      sock.close rescue nil
      nil
    end
  rescue *NETWORK_ERRORS
    sock&.close rescue nil
    nil
  end

  def http_connect_tunnel(sock, host, port)
    sock.write("CONNECT #{host}:#{port} HTTP/1.1\r\nHost: #{host}:#{port}\r\n\r\n")
    status_line = sock.gets
    return close_and_nil(sock) unless status_line&.split(' ', 3)&.at(1).to_i == 200

    loop { line = sock.gets; break if line.nil? || line == "\r\n" }
    sock
  rescue *NETWORK_ERRORS
    close_and_nil(sock)
  end

  def socks5_tunnel(sock, host, port)
    sock.write("\x05\x01\x00")
    return close_and_nil(sock) unless sock.read(2) == "\x05\x00"

    host_b  = host.b
    request = [ 0x05, 0x01, 0x00, 0x03, host_b.bytesize ].pack('C5') + host_b + [ port ].pack('n')
    sock.write(request)

    head = sock.read(4)
    return close_and_nil(sock) unless head&.length == 4 && head.getbyte(0) == 0x05 && head.getbyte(1) == 0x00

    case head.getbyte(3)
    when 0x01 then sock.read(6)
    when 0x03 then sock.read(sock.read(1).ord + 2)
    when 0x04 then sock.read(18)
    end

    sock
  rescue *NETWORK_ERRORS
    close_and_nil(sock)
  end

  # connect_nonblock + IO.select loop with an explicit deadline. ssl.connect can
  # block the reactor thread on some Ruby/io-event/platform combos, so we drive
  # the handshake non-blocking. Safe in both Async and non-Async contexts.
  def ssl_connect(ssl)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
    loop do
      ssl.connect_nonblock
      return true
    rescue IO::WaitReadable
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return false if remaining <= 0
      IO.select([ ssl.to_io ], nil, nil, remaining) or return false
    rescue IO::WaitWritable
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return false if remaining <= 0
      IO.select(nil, [ ssl.to_io ], nil, remaining) or return false
    rescue *NETWORK_ERRORS
      return false
    end
  end

  def write_request(io, method, uri, headers, body)
    lines = [ "#{method} #{uri.request_uri} HTTP/1.0", "Host: #{uri.host}" ]
    headers.each { |k, v| lines << "#{k}: #{v}" }
    lines << "Content-Length: #{body.bytesize}" if body
    io.write(lines.join("\r\n") + "\r\n\r\n")
    io.write(body) if body
  end

  # HTTP/1.0: server closes the connection after the response, so io.read gives
  # the complete body without needing chunked-encoding or Content-Length parsing.
  def read_response(io)
    raw        = io.read.to_s
    header_end = raw.index("\r\n\r\n")
    return nil unless header_end

    lines  = raw[0, header_end].split("\r\n")
    status = lines.first&.split(' ', 3)&.at(1).to_i
    hdrs   = lines[1..].each_with_object({}) do |line, h|
      k, v = line.split(': ', 2)
      h[k.to_s.downcase] = v.to_s if k
    end

    Response.new(raw[header_end + 4..], hdrs, status, nil)
  end

  def build_multipart(payload)
    boundary = "----RubyMultipart#{SecureRandom.hex(12)}"
    body     = String.new(encoding: 'ASCII-8BIT')

    payload.each do |name, value|
      body << "--#{boundary}\r\n"
      if file_part?(value)
        body << %(Content-Disposition: form-data; name="#{name}"; filename="#{value.original_filename}"\r\n)
        body << "Content-Type: #{value.content_type}\r\n\r\n"
        body << value.read.b
      else
        body << %(Content-Disposition: form-data; name="#{name}"\r\n\r\n)
        body << value.to_s.b
      end
      body << "\r\n"
    end
    body << "--#{boundary}--\r\n"

    [ body, "multipart/form-data; boundary=#{boundary}" ]
  end

  def file_part?(value)
    value.respond_to?(:read) && value.respond_to?(:original_filename) && value.respond_to?(:content_type)
  end

  def close_and_nil(sock)
    sock&.close rescue nil
    nil
  end
end
