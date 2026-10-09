# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::Browser::NetTracker do
  # Stand-ins for Playwright's Page (event emitter) and Request; Request#method is the HTTP method, as in the gem.
  let(:page_class) do
    Class.new do
      def initialize
        @handlers = Hash.new { |hash, event| hash[event] = [] }
      end

      def on(event, handler)
        @handlers[event] << handler
      end

      def off(event, handler)
        @handlers[event].delete(handler)
      end

      def emit(event, request)
        @handlers[event].each { |handler| handler.call(request) }
      end

      def listeners
        @handlers.values.sum(&:size)
      end
    end
  end
  let(:request_class) do
    Struct.new(:url, :http_method, :status, :frame_url, :body, :reads) do
      def method(*)
        http_method
      end

      # Request#response: a Playwright call (blocks until the response exists). Counts reads; `body` may be a
      # lambda (to block or raise).
      def response
        self.reads = reads.to_i + 1
        response_class = Struct.new(:source) do
          def body
            source.respond_to?(:call) ? source.call : source
          end
        end
        response_class.new(body)
      end

      def existing_response
        status && Struct.new(:status).new(status)
      end

      def frame
        raise Playwright::Error.new(message: 'frame not ready') if frame_url == :detached

        Struct.new(:url).new(frame_url)
      end
    end
  end
  let(:page) { page_class.new }
  let!(:tracker) { described_class.new(page) }
  let(:clock) { ApplyMate::Client::Browser::Clock }
  let(:now) { [ 1_000.0 ] }

  before { allow(clock).to receive(:now_ms) { now.first } }

  def advance(milliseconds)
    now[0] += milliseconds
  end

  def finish(request, event: 'requestfinished')
    page.emit('request', request)
    advance(10)
    page.emit(event, request)
  end

  it 'records non-GET requests from any frame and ignores GETs' do
    post = request_class.new('https://jobs.example.com/api/apply', 'POST', 201, 'https://jobs.example.com/embed')
    finish(request_class.new('https://jobs.example.com/app.js', 'GET', 200, 'https://jobs.example.com/'))
    finish(post)

    expect(tracker.since(0)).to eq([ { url: post.url, method: 'POST', status: 201, at: 1_010.0,
                                       frame_url: 'https://jobs.example.com/embed', body: nil, body_error: nil } ])
  end

  it 'records a failed request with a nil status' do
    finish(request_class.new('https://example.com/graphql', 'PUT', nil, nil), event: 'requestfailed')

    expect(tracker.since(0).sole).to include(method: 'PUT', status: nil)
  end

  it 'skips analytics and captcha hosts, including subdomains and path-scoped entries' do
    ignored = %w[
      https://www.google-analytics.com/g/collect https://region1.analytics.google-analytics.com/g/collect
      https://www.google.com/recaptcha/api2/reload https://www.gstatic.com/recaptcha/x https://api.hcaptcha.com/x
      https://o1.ingest.sentry.io/api/1/envelope/ https://challenges.cloudflare.com/cdn-cgi/x
      https://browser-intake-datadoghq.com/api/v2/rum https://rum.browser-intake-datadoghq.eu/api/v2/rum
      https://browser-intake-us5-datadoghq.com/api/v2/logs
    ]
    ignored.each { |url| finish(request_class.new(url, 'POST', 200, nil)) }
    finish(request_class.new('https://www.google.com/forms/submit', 'POST', 200, nil))
    finish(request_class.new('https://www.gstatic.com/other', 'POST', 200, nil))

    expect(tracker.since(0).pluck(:url)).to eq(%w[https://www.google.com/forms/submit https://www.gstatic.com/other])
  end

  it 'keeps at most MAX_RECORDS, dropping the oldest' do
    (described_class::MAX_RECORDS + 5).times do |index|
      finish(request_class.new("https://example.com/#{index}", 'POST', 200, nil))
    end

    urls = tracker.since(0).pluck(:url)
    expect(urls.size).to eq(described_class::MAX_RECORDS)
    expect(urls.first).to eq('https://example.com/5')
  end

  it 'returns only records started at or after the mark' do
    finish(request_class.new('https://example.com/before', 'POST', 200, nil))
    mark = tracker.mark
    finish(request_class.new('https://example.com/after', 'POST', 200, nil))

    expect(tracker.since(mark).pluck(:url)).to eq([ 'https://example.com/after' ])
  end

  describe '#in_flight_since' do
    it 'counts non-GET requests started at or after the mark that have not ended, however old' do
      page.emit('request', request_class.new('https://example.com/before', 'POST', nil, nil))
      advance(1) # a request started in the mark's own millisecond counts (`>=`), as #since does
      mark = tracker.mark
      submit = request_class.new('https://jobs.example.com/graphql', 'POST', nil, nil)
      page.emit('request', submit)
      page.emit('request', request_class.new('https://example.com/app.js', 'GET', nil, nil))
      page.emit('request', request_class.new('https://www.google-analytics.com/g/collect', 'POST', nil, nil))
      advance(30_000)

      expect(tracker.in_flight_since(mark)).to eq(1)

      page.emit('requestfinished', submit)
      expect(tracker.in_flight_since(mark)).to eq(0)
    end
  end

  describe '#pending' do
    it 'counts young in-flight requests of any method, ignores old ones and evicts stale ones' do
      long_poll = request_class.new('https://example.com/poll', 'GET', nil, nil)
      page.emit('request', long_poll)
      advance(4_000)
      page.emit('request', request_class.new('https://example.com/api', 'GET', nil, nil))

      expect(tracker.pending).to eq(1)
      expect(tracker.pending(ignore_older_ms: 5_000)).to eq(2)

      advance(57_000)
      expect(tracker.pending).to eq(0) # long_poll is 61 s old: evicted for good; the other one (57 s) stays
      expect(tracker.pending(ignore_older_ms: 120_000)).to eq(1)
    end

    it 'drops finished and failed requests and tracks the last network event' do
      expect(tracker.last_event_at).to eq(-Float::INFINITY)

      request = request_class.new('https://example.com/api', 'GET', 200, nil)
      page.emit('request', request)
      expect(tracker.pending).to eq(1)

      advance(25)
      page.emit('requestfailed', request)
      expect(tracker.pending).to eq(0)
      expect(tracker.last_event_at).to eq(1_025.0)
    end
  end

  it 'never raises on the reader thread when a request misbehaves' do
    broken = request_class.new('not a url at all', 'POST', 200, :detached)

    expect { finish(broken) }.not_to raise_error
    expect(tracker.since(0).sole).to include(url: 'not a url at all', frame_url: nil)
  end

  describe '#watch (response bodies)' do
    let(:graphql) { 'https://jobs.ashbyhq.com/api/non-user-graphql?op=ApiSubmit' }

    before { tracker.watch(%r{jobs\.ashbyhq\.com/api/non-user-graphql}) }

    after { tracker.dispose }

    it 'captures the body of a watched request, capped at BODY_CAP, only when asked for' do
      request = request_class.new(graphql, 'POST', 200, nil, "{\"data\":#{'x' * 70.kilobytes}")
      finish(request)

      expect(tracker.since(0, bodies: true).sole[:body].bytesize).to eq(described_class::BODY_CAP)
      expect(tracker.since(0, bodies: true).sole[:body]).to start_with('{"data":')
      expect(tracker.since(0).sole[:body]).to be_nil
    end

    it 'never reads the body of unwatched, GET or failed requests' do
      other = request_class.new('https://jobs.ashbyhq.com/api/other', 'POST', 200, nil, 'secret')
      get = request_class.new(graphql, 'GET', 200, nil, 'page')
      failed = request_class.new(graphql, 'POST', nil, nil, 'never')
      finish(other)
      finish(get)
      finish(failed, event: 'requestfailed')

      expect(tracker.since(0, bodies: true).map { |record| record.slice(:body, :body_error) })
        .to eq([ { body: nil, body_error: nil } ] * 2)
      expect([ other, get, failed ].map(&:reads)).to eq([ nil, nil, nil ])
    end

    it 'reads off the reader thread: a slow body read never blocks the event callback' do
      gate = Queue.new
      request = request_class.new(graphql, 'POST', 200, nil, -> { gate.pop })
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      finish(request)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
      gate << '{"data":{"ok":true}}'
      expect(tracker.since(0, bodies: true).sole[:body]).to eq('{"data":{"ok":true}}')
    end

    it "drops bodies (nil, body_error 'dropped', no raise) once BODY_QUEUE reads are waiting" do
      gate = Queue.new
      blocked = Array.new(described_class::BODY_QUEUE + 2) do |index|
        request_class.new("#{graphql}&n=#{index}", 'POST', 200, nil, -> { gate.pop })
      end
      expect { blocked.each { |request| finish(request) } }.not_to raise_error

      (described_class::BODY_QUEUE + 1).times { gate << 'ok' }
      records = tracker.since(0, bodies: true)
      expect(records.first(described_class::BODY_QUEUE + 1).pluck(:body)).to all(eq('ok')) # 1 running + BODY_QUEUE waiting
      expect(records.last).to include(body: nil, body_error: 'dropped') # the queue was full
    end

    it "records a failed body read as nil, body_error 'unreadable'" do
      finish(request_class.new(graphql, 'POST', 200, nil, -> { raise Playwright::Error.new(message: 'gone') }))

      expect(tracker.since(0, bodies: true).sole).to include(status: 200, body: nil, body_error: 'unreadable')
    end

    it 'gives up waiting for a body after BODY_WAIT_MS' do
      stub_const("#{described_class}::BODY_WAIT_MS", 50)
      gate = Queue.new
      finish(request_class.new(graphql, 'POST', 200, nil, -> { gate.pop }))

      expect(tracker.since(0, bodies: true).sole).to include(body: nil, body_error: 'timeout')
      gate << 'late'
    end

    it 'accepts only a Regexp' do
      expect { tracker.watch('non-user-graphql') }.to raise_error(ArgumentError, /Regexp/)
    end
  end

  it 'unsubscribes on dispose' do
    expect(page.listeners).to eq(3)

    tracker.dispose

    expect(page.listeners).to eq(0)
  end
end
