# frozen_string_literal: true

require 'async/http/internet'

class ApplyMate::Client::AsyncHttp < ApplyMate::Client::Base
  HTTP_PROTOCOLS   = %w[http https].freeze
  SOCKS5_PROTOCOLS = %w[socks5 socks5h].freeze
  CONNECT_TIMEOUT  = 5

  def initialize(timeout: 10, proxy:)
    @timeout = timeout
    @proxy_uri = URI.parse(proxy)
    @ssl_ctx   = OpenSSL::SSL::SSLContext.new.tap(&:set_params)
  end

  def get(url, headers: {}, error_handler: default_error_handler, **)
    proxy_request(:GET, url, headers: headers).tap do |result|
      raise DeadProxyError, "Proxy #{@proxy_uri} failed for #{url}" if result.nil?
    end
  end

  def fetch_body(url, error_handler: default_error_handler, **)
    get(url, error_handler: error_handler)&.body
  end

  def post(url, body:, headers: {}, error_handler: default_error_handler, **)
    proxy_request(:POST, url, headers: headers, body: body).tap do |result|
      raise DeadProxyError, "Proxy #{@proxy_uri} failed for #{url}" if result.nil?
    end
  end

  def post_xhr(url, body, headers = {}, error_handler: default_error_handler)
    post(url, body: body, headers: headers, error_handler: error_handler)&.body
  end

  private

  # All proxy failures return nil (never raise), so the error_handler in get/post
  # never retries — a dead proxy should fail fast, not burn 5 retry slots.
  def proxy_request(method, url, headers:, body: nil)
    uri  = URI.parse(url)
    host = uri.host
    port = uri.port || (uri.scheme == 'https' ? 443 : 80)

    Async::Task.current.with_timeout(@timeout) do
      sock = open_tunnel(host, port)
      return nil unless sock

      io  = sock
      ssl = nil
      begin
        if uri.scheme == 'https'
          ssl = OpenSSL::SSL::SSLSocket.new(sock, @ssl_ctx)
          ssl.hostname   = host
          ssl.sync_close = true
          return nil unless ssl_connect(ssl)
          io  = ssl
          ssl = nil
        end

        write_request(io, method, uri, headers, body)
        read_response(io)
      rescue StandardError
        nil
      ensure
        io.close  rescue nil
        ssl&.close rescue nil
      end
    end
  rescue Async::TimeoutError, StandardError
    nil
  end

  def open_tunnel(host, port)
    sock = Socket.tcp(@proxy_uri.host, @proxy_uri.port.to_i, connect_timeout: CONNECT_TIMEOUT)
    return nil unless sock

    case @proxy_uri.scheme.to_s.downcase
    when *HTTP_PROTOCOLS   then http_connect_tunnel(sock, host, port)
    when *SOCKS5_PROTOCOLS then socks5_tunnel(sock, host, port)
    else
      sock.close rescue nil
      nil
    end
  rescue StandardError
    sock&.close rescue nil
    nil
  end

  def http_connect_tunnel(sock, host, port)
    sock.write("CONNECT #{host}:#{port} HTTP/1.1\r\nHost: #{host}:#{port}\r\n\r\n")
    status_line = sock.gets
    return nil unless status_line&.split(' ', 3)&.at(1).to_i == 200
    loop { line = sock.gets; break if line.nil? || line == "\r\n" }
    sock
  rescue StandardError
    sock.close rescue nil
    nil
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
    when 0x03 then sock.read(sock.read(1).ord + 2)
    when 0x04 then sock.read(18)
    end

    sock
  rescue StandardError
    sock.close rescue nil
    nil
  end

  # connect_nonblock + IO.select loop — same pattern as ValidateCandidates.
  # ssl.connect can block the reactor thread on some Ruby/io-event/platform combos.
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
    rescue StandardError
      return false
    end
  end

  def write_request(io, method, uri, extra_headers, body)
    lines = [ "#{method} #{uri.request_uri} HTTP/1.0", "Host: #{uri.host}" ]
    build_headers(extra_headers).each { |k, v| lines << "#{k}: #{v}" }
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

    Response.new(raw[header_end + 4..], hdrs, status)
  end

  def default_error_handler
    ApplyMate::Client::ErrorHandler.new(max_retries: 5, base_delay: 1)
  end

  def build_headers(extra = {})
    [ [ 'User-Agent', USER_AGENT ] ] + extra.map { |k, v| [ k.to_s, v.to_s ] }
  end

  def extract_headers(headers)
    result = {}
    headers.each { |k, v| result[k.to_s.downcase] ||= v.to_s }
    result
  end
end
