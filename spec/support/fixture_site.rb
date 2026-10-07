# frozen_string_literal: true

require 'puma'

# Static pages the real browser (browserd's Camoufox) loads in :browser specs. Served by an in-process Puma bound to
# 0.0.0.0 on a free port so the browserd container reaches it as http://$FIXTURE_SITE_HOST:<port>
# (default host.docker.internal; browserd's dev/CI EGRESS_ALLOW_RANGES lets smokescreen reach that private address).
#
# Routes: GET /<page>.html and /slow-reveal.js from fixture_site/pages (form.html also sets a cookie),
# POST /submit -> 200 "Thank you for applying", anything else 404.
module FixtureSite
  PAGES_DIR = Pathname(__dir__).join('fixture_site/pages')
  CONTENT_TYPES = { '.html' => 'text/html; charset=utf-8', '.js' => 'text/javascript' }.freeze

  APP = lambda do |env|
    request = Rack::Request.new(env)
    next [ 200, { 'content-type' => CONTENT_TYPES['.html'] }, [ '<h1>Thank you for applying</h1>' ] ] \
      if request.post? && request.path == '/submit'

    file = PAGES_DIR.join(request.path.delete_prefix('/'))
    next [ 404, { 'content-type' => 'text/plain' }, [ 'not found' ] ] \
      unless request.get? && CONTENT_TYPES.key?(file.extname) && file.dirname == PAGES_DIR && file.file?

    headers = { 'content-type' => CONTENT_TYPES[file.extname] }
    headers['set-cookie'] = 'fixture_session=abc123; Path=/' if file.basename.to_s == 'form.html'
    [ 200, headers, [ file.read ] ]
  end

  class << self
    attr_reader :port

    def start
      return if @server

      @server = Puma::Server.new(APP, nil, { min_threads: 0, max_threads: 4, log_writer: Puma::LogWriter.null })
      @server.add_tcp_listener('0.0.0.0', 0)
      @port = @server.connected_ports.first
      @server.run
    end

    def stop
      @server&.stop(true)
      @server = nil
    end

    def host
      ENV.fetch('FIXTURE_SITE_HOST', 'host.docker.internal')
    end

    def url(path)
      "http://#{host}:#{port}#{path}"
    end

    # What the PublicAddressGuard seam in browser_tag.rb returns for fixture URLs.
    def resolution(url)
      uri = URI.parse(url)
      ApplyMate::Operation::Result.new.tap do |result|
        result[:model] = ApplyMate::Net::Operation::ResolvePublicAddress::Resolution.new(
          url:, host: uri.host, port: uri.port, ip: nil
        )
      end
    end
  end
end
