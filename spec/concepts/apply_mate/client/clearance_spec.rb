# frozen_string_literal: true

require 'rails_helper'
require 'socket'

RSpec.describe ApplyMate::Client::Clearance do
  let(:url)     { 'https://rubyonremote.com/remote-jobs/?page=2' }
  let(:headers) { { 'Cookie' => 'cf_clearance=tok', 'User-Agent' => 'Chrome/151' } }

  # The test environment runs on the null store, and a cache that forgets everything
  # would make every "warmed once" claim below true by accident.
  before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

  describe '.headers' do
    it 'warms once and serves the same token to every later caller' do
      warmed = 0
      allow(described_class).to receive(:new) do
        warmed += 1
        instance_double(described_class, call: headers)
      end

      expect(described_class.headers(url)).to eq(headers)
      expect(described_class.headers('https://rubyonremote.com/jobs/1')).to eq(headers)
      expect(warmed).to eq(1)
    end

    # The token belongs to the address that earned it, so a client on another exit IP
    # must not inherit it — it would be refused, and the refusal would read as the
    # site blocking that proxy.
    it 'keeps the token of one exit IP away from another' do
      allow(described_class).to receive(:new).and_return(instance_double(described_class, call: headers))
      described_class.headers(url)

      expect(described_class).to receive(:new).with(anything, proxy: 'socks5://1.2.3.4:1080')
                                              .and_return(instance_double(described_class, call: headers))
      described_class.headers(url, proxy: 'socks5://1.2.3.4:1080')
    end

    it 'points the browser at the origin, not at the deep link that needed it' do
      expect(described_class).to receive(:new)
        .with(URI('https://rubyonremote.com/'), proxy: nil)
        .and_return(instance_double(described_class, call: headers))

      described_class.headers(url)
    end

    it 'asks for nothing when the URL has no host' do
      expect(described_class).not_to receive(:new)
      expect(described_class.headers('not a url')).to eq({})
    end

    # A failed warm-up must not be remembered as "this host needs no headers": the
    # next request would go out bare and read the challenge page as an empty listing.
    it 'caches nothing when the warm-up fails' do
      allow(described_class).to receive(:new)
        .and_return(instance_double(described_class).tap { |c| allow(c).to receive(:call).and_raise(described_class::ChallengeError) })

      expect { described_class.headers(url) }.to raise_error(described_class::ChallengeError)
      expect(Rails.cache.read('clearance/rubyonremote.com/direct')).to be_nil
    end
  end

  describe '.forget' do
    it 'drops the token so the next caller earns a fresh one' do
      allow(described_class).to receive(:new).and_return(instance_double(described_class, call: headers))
      described_class.headers(url)

      described_class.forget(url)

      expect(described_class).to receive(:new).and_return(instance_double(described_class, call: headers))
      described_class.headers(url)
    end
  end

  # The whole point of the class is what a browser does that no HTTP client can, so
  # the warm-up is exercised against a real Chrome and a server that behaves like a
  # challenge: first response is the interstitial that reloads itself, second is the
  # real page with the clearance cookie on it.
  describe '#call', :aggregate_failures do
    let(:server) { TCPServer.new('127.0.0.1', 0) }
    let(:port)   { server.addr[1] }
    let(:visits) { Concurrent::Array.new }

    # The interstitial reloads itself, exactly like Cloudflare's does — that is what
    # gives the poll loop a title to see changing.
    CHALLENGE_PAGE = "<html><head><title>Just a moment...</title>" \
                     "<meta http-equiv='refresh' content='1'></head><body>checking</body></html>"
    CLEARED_PAGE   = '<html><head><title>Vacancies</title></head><body>ok</body></html>'

    before do
      skip 'the warm-up needs a display (headless never clears a real challenge)' if ENV['DISPLAY'].blank?

      @serving = Thread.new do
        loop do
          socket = server.accept
          Thread.new(socket) { |client| serve(client) }
        rescue StandardError
          break
        end
      end
    end

    after do
      @serving&.kill
      server.close unless server.closed?
    end

    # One connection: read the request line, drain the headers, answer, hang up.
    def serve(socket)
      path = socket.gets.to_s.split[1]
      while (line = socket.gets)
        break if line.strip.empty?
      end
      respond(socket, path)
    rescue StandardError
      socket.close rescue nil
    end

    def respond(socket, path)
      if path != '/'
        socket.print("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        return socket.close
      end

      visits << path
      body   = visits.size == 1 ? CHALLENGE_PAGE : CLEARED_PAGE
      cookie = visits.size == 1 ? '' : "Set-Cookie: cf_clearance=granted-by-spec; Path=/\r\n"
      socket.print("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n#{cookie}" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      socket.close
    end

    it 'waits out the challenge and returns the cookie with the UA that earned it' do
      result = described_class.new("http://127.0.0.1:#{port}/").call

      expect(result['Cookie']).to eq('cf_clearance=granted-by-spec')
      expect(result['User-Agent']).to include('Chrome/')
      expect(visits.size).to be >= 2
    end

    # Chrome is killed, not asked to leave, and it spawns a tree of helpers — a
    # warm-up that leaked one of them per sync would eat the host.
    it 'leaves no Chrome behind' do
      described_class.new("http://127.0.0.1:#{port}/").call

      # Given a moment: the browser process is waited for, but the renderers it
      # spawned take theirs to notice the group signal.
      remaining = 25.times do
        break 0 if chrome_processes_on('clearance-127.0.0.1').zero?

        sleep 0.2
      end
      expect(remaining).to eq(0)
    end

    # Read from /proc rather than pgrep, whose own command line carries the pattern
    # and matches itself.
    def chrome_processes_on(profile)
      Dir.glob('/proc/[0-9]*/cmdline').count do |path|
        cmdline = File.read(path)
        cmdline.include?(profile) && cmdline.include?('chrome')
      rescue StandardError
        false
      end
    end
  end

  describe '#call when the host cannot run a browser' do
    it 'says so instead of blaming the site' do
      allow(ApplyMate::Client::Browser).to receive(:chrome_path).and_return(nil)

      expect { described_class.new('https://rubyonremote.com/').call }
        .to raise_error(described_class::BrowserError, /no Chrome binary/)
    end
  end
end
