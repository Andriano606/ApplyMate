# frozen_string_literal: true

require 'open3'
require 'tempfile'

# HTTP client that speaks with a real Chrome's TLS + HTTP/2 fingerprint by shelling
# out to curl-impersonate. Cloudflare-protected sites (e.g. Dou) reject our pure-Ruby
# AsyncHttp because OpenSSL's JA3/JA4 fingerprint isn't Chrome's — even with perfect
# headers. curl-impersonate (BoringSSL + Chrome cipher/extension order + HTTP/2
# settings) passes the non-interactive Cloudflare challenge WITHOUT a browser and at
# HTTP speed, and (unlike a headless browser) sustains many requests per proxy.
#
# Drop-in for ApplyMate::Client::AsyncHttp: same Response shape and #get/#post, so a
# scraper can take it as its client unchanged.
#
# The curl-impersonate binary is arch-specific and NOT committed. Install it with
# `bin/install-curl-impersonate` (downloads the right build into vendor/, gitignored)
# or point CURL_IMPERSONATE_BIN at a wrapper (e.g. curl_chrome136) on the host.
class ApplyMate::Client::ImpersonateHttp
  Response = ApplyMate::Client::Response

  class RequestError < StandardError; end

  # Chrome-impersonation wrapper (sets the TLS/HTTP2 fingerprint + Chrome headers).
  BINARY = ENV.fetch('CURL_IMPERSONATE_BIN') do
    Rails.root.join('vendor/curl-impersonate/curl_chrome136').to_s
  end

  DEFAULT_REQUEST_TIMEOUT = 15
  DEFAULT_CONNECT_TIMEOUT = 5

  def initialize(proxy: nil, request_timeout: DEFAULT_REQUEST_TIMEOUT, connect_timeout: DEFAULT_CONNECT_TIMEOUT)
    @proxy           = proxy
    @request_timeout = request_timeout
    @connect_timeout = connect_timeout
  end

  def get(url, headers: {}, follow_redirects: true, **)
    run(url, headers: headers, follow_redirects: follow_redirects)
  end

  def post(url, body:, headers: {}, **)
    run(url, method: 'POST', body: body, headers: headers, follow_redirects: true)
  end

  private

  def run(url, method: 'GET', body: nil, headers: {}, follow_redirects: true)
    body_file = Tempfile.new('ci_body')
    hdr_file  = Tempfile.new('ci_hdr')
    begin
      # Body → -o file, headers → -D file, so stdout carries ONLY the -w http_code.
      stdout, stderr, status = Open3.capture3(*command(url, method, body, headers, follow_redirects, body_file, hdr_file))
      raise RequestError, "curl-impersonate failed (exit #{status.exitstatus}): #{stderr.strip}" unless status.success?

      Response.new(File.read(body_file.path), parse_headers(File.read(hdr_file.path)), stdout.to_i, url)
    ensure
      body_file.close!
      hdr_file.close!
    end
  end

  def command(url, method, body, headers, follow_redirects, body_file, hdr_file)
    args = [ BINARY, '-sS', '-o', body_file.path, '-D', hdr_file.path, '-w', '%{http_code}',
             '--max-time', @request_timeout.to_s, '--connect-timeout', @connect_timeout.to_s ]
    args << '-L' if follow_redirects
    if (proxy = proxy_arg)
      args.push('--proxy', proxy)
    end
    if method == 'POST'
      args.push('-X', 'POST', '--data-binary', body.to_s)
    end
    headers.each { |key, value| args.push('-H', "#{key}: #{value}") }
    args << url
    args
  end

  # http://  → passed through; socks5:// → socks5h:// so DNS resolves through the
  # proxy (datacenter proxies often can't be reached for local DNS of the target).
  def proxy_arg
    return nil if @proxy.blank?

    uri = URI.parse(@proxy.to_s)
    uri.scheme.to_s.start_with?('socks') ? "socks5h://#{uri.host}:#{uri.port}" : @proxy.to_s
  end

  # curl -D dumps every header block (proxy CONNECT, redirects, final response).
  # Mirror AsyncHttp: lowercase keys, Set-Cookie collected into an Array (Django +
  # Cloudflare emit several), everything else last-wins.
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
