# frozen_string_literal: true

require 'puma'

# Static pages the real browser (browserd's Camoufox) loads in :browser specs. Served by an in-process Puma bound to
# 0.0.0.0 on two free ports so the browserd container reaches it as http://$FIXTURE_SITE_HOST:<port> and, as a
# second (cross-origin) site, http://$FIXTURE_SITE_HOST:<alt_port> (default host.docker.internal; browserd's dev/CI
# EGRESS_ALLOW_RANGES lets smokescreen reach that private address). Both ports serve the same routes.
#
# Routes:
# - GET /<path>.html|.js from fixture_site/pages (subdirectories allowed, never outside it); `{{ORIGIN}}` and
#   `{{ALT_ORIGIN}}` in .html bodies become the two origins. form.html also sets a cookie.
# - GET /ashby/<slug>/<jid uuid>/application -> ashby/application.html (the canonical form URL of an Ashby adapter
#   whose origin is alt_url('/ashby'), see FixtureAshby in fixture_ashby_platform.rb)
# - GET /ashby/<slug>/<jid uuid> -> ashby/posting.html (the job URL the embed deep-links for ?ashby_jid=)
# - GET /ashby/posting.json -> spec/fixtures/files/apply_engine/ashby/api_job_posting.json
# - POST /ashby/api/non-user-graphql?op=ApiJobPosting -> the posting JSON above (the schema read of
#   Apply::Operation::Platform::Ashby::FetchSchema; not recorded)
# - POST /ashby/api/non-user-graphql?op=<any other op> -> recorded in FixtureSite.submissions as { op:, body: }
#   after the FixtureSite.on_submit hooks ran (in the server thread; a spec reads the DB there, e.g. to prove the
#   submit claim was taken before the POST), answers {"data":{"submitApplicationForm":{"success":true}}}
# - POST /submit -> 200 "Thank you for applying"
# - anything else 404.
module FixtureSite
  PAGES_DIR = Pathname(__dir__).join('fixture_site/pages')
  ASHBY_POSTING_JSON = Rails.root.join('spec/fixtures/files/apply_engine/ashby/api_job_posting.json')
  CONTENT_TYPES = { '.html' => 'text/html; charset=utf-8', '.js' => 'text/javascript' }.freeze
  JSON_HEADERS = { 'content-type' => 'application/json' }.freeze
  NOT_FOUND = [ 404, { 'content-type' => 'text/plain' }, [ 'not found' ] ].freeze
  ASHBY_JOB = %r{\A/ashby/[^/]+/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}}
  ASHBY_PAGES = { %r{#{ASHBY_JOB}/application\z} => 'ashby/application.html', /#{ASHBY_JOB}\z/ => 'ashby/posting.html' }.freeze

  APP = lambda do |env|
    request = Rack::Request.new(env)
    next [ 200, { 'content-type' => CONTENT_TYPES['.html'] }, [ '<h1>Thank you for applying</h1>' ] ] \
      if request.post? && request.path == '/submit'

    if request.post? && request.path == '/ashby/api/non-user-graphql'
      next [ 200, JSON_HEADERS, [ ASHBY_POSTING_JSON.read ] ] if request.GET['op'] == 'ApiJobPosting'

      submission = { op: request.GET['op'], body: request.body.read }
      FixtureSite.submit_hooks.each { |hook| hook.call(submission) }
      FixtureSite.submissions << submission
      next [ 200, JSON_HEADERS, [ '{"data":{"submitApplicationForm":{"success":true}}}' ] ]
    end
    next [ 200, JSON_HEADERS, [ ASHBY_POSTING_JSON.read ] ] if request.get? && request.path == '/ashby/posting.json'

    FixtureSite.page(request)
  end

  class << self
    attr_reader :port, :alt_port

    def start
      return if @server

      @server = Puma::Server.new(APP, nil, { min_threads: 0, max_threads: 4, log_writer: Puma::LogWriter.null })
      2.times { @server.add_tcp_listener('0.0.0.0', 0) }
      @port, @alt_port = @server.connected_ports
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

    def alt_url(path)
      "http://#{host}:#{alt_port}#{path}"
    end

    def submissions
      @submissions ||= Concurrent::Array.new
    end

    # Runs `block` with each recorded submission before it is stored (cleared by reset!).
    def on_submit(&block)
      submit_hooks << block
    end

    def submit_hooks
      @submit_hooks ||= Concurrent::Array.new
    end

    def reset!
      submissions.clear
      submit_hooks.clear
    end

    def page(request)
      path = ASHBY_PAGES.find { |pattern, _page| request.path.match?(pattern) }&.last || request.path.delete_prefix('/')
      file = PAGES_DIR.join(path).cleanpath
      return NOT_FOUND unless request.get? && CONTENT_TYPES.key?(file.extname) &&
                              file.to_s.start_with?("#{PAGES_DIR}/") && file.file?

      headers = { 'content-type' => CONTENT_TYPES[file.extname] }
      headers['set-cookie'] = 'fixture_session=abc123; Path=/' if file.basename.to_s == 'form.html'
      body = file.read
      body = body.gsub('{{ORIGIN}}', url('')).gsub('{{ALT_ORIGIN}}', alt_url('')) if file.extname == '.html'
      [ 200, headers, [ body ] ]
    end

    # PublicAddressGuard seam (browser_tag.rb): the fixture host is private. The server runs in this process, so a
    # pinned Ruby-side fetch (GuardedFetch, curl --resolve) reaches it on 127.0.0.1.
    def resolution(url)
      uri = URI.parse(url)
      ApplyMate::Operation::Result.new.tap do |result|
        result[:model] = ApplyMate::Net::Operation::ResolvePublicAddress::Resolution.new(
          url:, host: uri.host, port: uri.port, ip: '127.0.0.1'
        )
      end
    end
  end
end
