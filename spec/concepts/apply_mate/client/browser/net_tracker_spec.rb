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
    Struct.new(:url, :http_method, :status, :frame_url) do
      def method(*)
        http_method
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
                                       frame_url: 'https://jobs.example.com/embed' } ])
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

  it 'unsubscribes on dispose' do
    expect(page.listeners).to eq(3)

    tracker.dispose

    expect(page.listeners).to eq(0)
  end
end
