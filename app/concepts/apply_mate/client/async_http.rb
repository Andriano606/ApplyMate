# frozen_string_literal: true

require 'async'
require 'kernel/sync'
require 'resolv'

class ApplyMate::Client::AsyncHttp
  Response = Struct.new(:body, :headers, :status, :final_url)

  USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
  MAX_REDIRECTS   = 5
  TCP_CONNECT_TIMEOUT = 5
  HTTP_PROTOCOLS   = %w[http https].freeze
  SOCKS5_PROTOCOLS = %w[socks5 socks5h].freeze
  DNS_CACHE = Concurrent::Map.new
  DNS_TTL_S = 300

  def initialize(request_timeout: 15, proxy: nil)
    @request_timeout = request_timeout
    @proxy_uri       = proxy.present? ? URI.parse(proxy) : nil
    @ssl_ctx         = OpenSSL::SSL::SSLContext.new.tap(&:set_params)
  end

  def get(url, headers: {}, follow_redirects: true, **)
    perform(:GET, url, headers: headers, follow_redirects: follow_redirects)
  end

  def post(url, body:, headers: {}, **)
    perform(:POST, url, body: body, headers: headers, follow_redirects: true)
  end

  def post_multipart(url, payload:, headers: {})
    body, content_type = build_multipart(payload)
    extra_headers      = headers.merge('Content-Type' => content_type)
    perform(:POST, url, body: body, headers: extra_headers, follow_redirects: false)
  end

  private

  def merge_default_headers(extra = {})
    extra.each_with_object('User-Agent' => USER_AGENT) { |(k, v), h| h[k.to_s] = v.to_s }
  end

  def resolve(host)
    return host if host.nil? || host.empty?
    return host if host.match?(/\A\d{1,3}(\.\d{1,3}){3}\z/) || host.include?(':')

    entry = DNS_CACHE[host]
    now   = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return entry[:ip] if entry && entry[:expires_at] > now

    ip = Resolv.getaddress(host)
    DNS_CACHE[host] = { ip: ip, expires_at: now + DNS_TTL_S }
    ip
  end

  def perform(method, url, headers:, body: nil, follow_redirects:)
    full_headers = merge_default_headers(headers)
    with_timeout { request_with_redirects(method, url, full_headers, body, MAX_REDIRECTS, follow_redirects) }
  end

  def request_with_redirects(method, url, headers, body, remaining, follow_redirects)
    response = send_once(method, url, headers, body)
    return nil if response.nil?

    if follow_redirects && (300..399).cover?(response.status) && remaining.positive?
      location = response.headers['location']
      if location.present?
        new_url     = URI.join(url, location).to_s
        new_method  = [ 307, 308 ].include?(response.status) ? method : :GET
        new_body    = new_method == :GET ? nil : body
        new_headers = redirect_headers(headers, url, new_url)
        return request_with_redirects(new_method, new_url, new_headers, new_body, remaining - 1, follow_redirects)
      end
    end

    response.final_url = url
    response
  end

  def redirect_headers(headers, from_url, to_url)
    return headers if URI.parse(from_url).host == URI.parse(to_url).host

    headers.reject { |k, _| %w[cookie authorization].include?(k.to_s.downcase) }
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
    ensure
      io.close   rescue nil
      ssl&.close rescue nil
    end
  end

  def with_timeout(&block)
    if Async::Task.current?
      Async::Task.current.with_timeout(@request_timeout, &block)
    else
      Sync { Async::Task.current.with_timeout(@request_timeout, &block) }
    end
  end

  def open_tunnel(host, port)
    return Socket.tcp(resolve(host), port.to_i, connect_timeout: TCP_CONNECT_TIMEOUT) if @proxy_uri.nil?

    sock        = Socket.tcp(resolve(@proxy_uri.host), @proxy_uri.port.to_i, connect_timeout: TCP_CONNECT_TIMEOUT)
    established = false
    result      = case @proxy_uri.scheme.to_s.downcase
    when *HTTP_PROTOCOLS   then http_connect_tunnel(sock, host, port)
    when *SOCKS5_PROTOCOLS then socks5_tunnel(sock, host, port)
    end
    established = !result.nil?
    result
  ensure
    if sock && !established
      sock.close rescue nil
    end
  end

  def http_connect_tunnel(sock, host, port)
    sock.write("CONNECT #{host}:#{port} HTTP/1.1\r\nHost: #{host}:#{port}\r\n\r\n")
    status_line = sock.gets
    return nil unless status_line&.split(' ', 3)&.at(1).to_i == 200

    loop { line = sock.gets; break if line.nil? || line == "\r\n" }
    sock
  end

  def socks5_tunnel(sock, host, port)
    sock.write("\x05\x01\x00")
    return nil unless sock.read(2) == "\x05\x00"

    host_b  = host.b
    request = [ 0x05, 0x01, 0x00, 0x03, host_b.bytesize ].pack('C5') + host_b + [ port ].pack('n')
    sock.write(request)

    head = sock.read(4)
    return nil unless head&.length == 4 && head.getbyte(0) == 0x05 && head.getbyte(1) == 0x00

    case head.getbyte(3)
    when 0x01 then sock.read(6)
    when 0x03
      len = sock.read(1)
      return nil unless len
      sock.read(len.ord + 2)
    when 0x04 then sock.read(18)
    end

    sock
  end

  def ssl_connect(ssl)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @request_timeout
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
    end
  end

  def write_request(io, method, uri, headers, body)
    lines = [ "#{method} #{uri.request_uri} HTTP/1.0", "Host: #{uri.host}" ]
    lines << 'Connection: close'
    lines << 'Accept-Encoding: identity'
    headers.each { |k, v| lines << "#{strip_crlf(k)}: #{strip_crlf(v)}" }
    lines << "Content-Length: #{body.bytesize}" if body
    io.write(lines.join("\r\n") + "\r\n\r\n")
    io.write(body) if body
  end

  # Strips CRLF to prevent header injection via crafted header names/values.
  def strip_crlf(value)
    value.to_s.delete("\r\n")
  end

  def read_response(io)
    header_blob, body_so_far = read_headers(io)

    lines  = header_blob.split("\r\n")
    status = lines.first&.split(' ', 3)&.at(1).to_i
    return nil unless status.positive?

    hdrs = parse_headers(lines[1..])

    Response.new(read_body(io, hdrs, body_so_far), hdrs, status, nil)
  end

  # Set-Cookie is the one response header servers legitimately send multiple
  # times (e.g. Django emitting csrftoken + sessionid, plus Cloudflare cookies).
  # Collapsing them into a single Hash key would keep only the last and silently
  # drop the rest — so set-cookie is accumulated into an Array, every other
  # header stays a String.
  def parse_headers(lines)
    lines.each_with_object({}) do |line, h|
      k, v = line.split(': ', 2)
      next unless k

      key = k.downcase
      if key == 'set-cookie'
        (h[key] ||= []) << v.to_s
      else
        h[key] = v.to_s
      end
    end
  end

  # Reads up to the end of the header block (\r\n\r\n) and returns
  # [header_string, leftover_body_bytes]. If the connection closes before the
  # headers are complete, readpartial raises EOFError — left to propagate.
  def read_headers(io)
    buffer = String.new(encoding: 'ASCII-8BIT')
    loop do
      idx = buffer.index("\r\n\r\n")
      return [ buffer[0, idx], buffer[idx + 4..] || '' ] if idx

      buffer << io.readpartial(16_384)
    end
  end

  # With Content-Length we read exactly that many bytes; a connection that drops
  # early makes readpartial raise EOFError (truncation surfaces as an error).
  # Without Content-Length the body is delimited by the connection close, so a
  # clean EOF via #read is the expected end — only a hard transport failure
  # (e.g. a TLS close without close_notify) raises. No errors are rescued here.
  def read_body(io, headers, body)
    length = headers['content-length']&.to_i

    if length
      body << io.readpartial(16_384) while body.bytesize < length
      body[0, length]
    else
      body << io.read.to_s
    end
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
end
