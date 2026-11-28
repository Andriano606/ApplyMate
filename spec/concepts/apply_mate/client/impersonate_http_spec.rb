# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::ImpersonateHttp do
  # Stubs the curl-impersonate subprocess: writes the body/header files curl would
  # have written (paths taken from the -o/-D args) and prints the -w WRITE_OUT lines
  # (http_code, exitcode, url_effective, errormsg) on stdout.
  def stub_curl(body: '<html>ok</html>', headers: "HTTP/1.1 200 OK\r\n", code: 200, exitcode: 0, errormsg: '', final_url: nil)
    allow(Open3).to receive(:capture3) do |*args|
      @captured = args
      # Read the request body while the tempfile still exists — `run` unlinks it in
      # its ensure block before the example gets a chance to look.
      idx = args.index('--data-binary')
      @request_body = idx ? File.read(args[idx + 1].delete_prefix('@')) : nil
      File.write(args[args.index('-o') + 1], body)
      File.write(args[args.index('-D') + 1], headers)
      status = instance_double(Process::Status, success?: exitcode.zero?, exitstatus: exitcode)
      [ [ exitcode.zero? ? code : 0, exitcode, final_url || args.last, errormsg ].join("\n"), '', status ]
    end
  end

  describe '#get' do
    it 'returns a Response with body, status, headers, and final_url' do
      stub_curl(body: '<html>real vacancies l-vacancy</html>',
                headers: "HTTP/1.1 200 OK\r\nServer: cloudflare\r\n", code: 200)
      response = described_class.new.get('https://jobs.dou.ua/vacancies/')

      expect(response).to be_a(described_class::Response)
      expect(response.status).to eq(200)
      expect(response.body).to eq('<html>real vacancies l-vacancy</html>')
      expect(response.headers['server']).to eq('cloudflare')
      expect(response.final_url).to eq('https://jobs.dou.ua/vacancies/')
    end

    it 'invokes curl-impersonate with the default Chrome target, follows redirects, and targets the URL' do
      stub_curl
      described_class.new.get('https://jobs.dou.ua/vacancies/')

      expect(@captured.first).to eq(described_class::BINARY)
      expect(@captured[@captured.index('--impersonate') + 1]).to eq('chrome146')
      expect(@captured).to include('--compressed', '-L')
      expect(@captured.last).to eq('https://jobs.dou.ua/vacancies/')
    end

    it 'passes the request and connect timeouts to curl' do
      stub_curl
      described_class.new(request_timeout: 12, connect_timeout: 4).get('https://x')

      expect(@captured[@captured.index('--max-time') + 1]).to eq('12')
      expect(@captured[@captured.index('--connect-timeout') + 1]).to eq('4')
    end

    it 'sends an HTTP proxy through unchanged' do
      stub_curl
      described_class.new(proxy: 'http://10.0.0.1:8080').get('https://x')

      expect(@captured[@captured.index('--proxy') + 1]).to eq('http://10.0.0.1:8080')
    end

    it 'rewrites a SOCKS5 proxy to socks5h (remote DNS through the proxy)' do
      stub_curl
      described_class.new(proxy: 'socks5://1.2.3.4:1080').get('https://x')

      expect(@captured[@captured.index('--proxy') + 1]).to eq('socks5h://1.2.3.4:1080')
    end

    # curl speaks SOCKS4/4a natively; forcing them to socks5h (the old behaviour) made every
    # SOCKS4 proxy fail its handshake.
    it 'passes SOCKS4 and SOCKS4a proxies through unchanged' do
      stub_curl
      described_class.new(proxy: 'socks4://1.2.3.4:1080').get('https://x')
      expect(@captured[@captured.index('--proxy') + 1]).to eq('socks4://1.2.3.4:1080')

      described_class.new(proxy: 'socks4a://1.2.3.4:1080').get('https://x')
      expect(@captured[@captured.index('--proxy') + 1]).to eq('socks4a://1.2.3.4:1080')
    end

    it 'omits --proxy when no proxy is configured' do
      stub_curl
      described_class.new.get('https://x')

      expect(@captured).not_to include('--proxy')
    end

    it 'forwards custom headers as -H args' do
      stub_curl
      described_class.new.get('https://x', headers: { 'Cookie' => 'csrftoken=abc', 'X-CSRFToken' => 'abc' })

      expect(@captured).to include('-H', 'Cookie: csrftoken=abc')
      expect(@captured).to include('-H', 'X-CSRFToken: abc')
    end

    it 'collects multiple Set-Cookie headers into an Array' do
      stub_curl(headers: "HTTP/1.1 200 OK\r\nSet-Cookie: csrftoken=abc; Path=/\r\nSet-Cookie: sessionid=xyz; Path=/\r\n")
      response = described_class.new.get('https://x')

      expect(response.headers['set-cookie']).to eq([ 'csrftoken=abc; Path=/', 'sessionid=xyz; Path=/' ])
    end

    context 'with a Cloudflare clearance from ProxyMate' do
      let(:clearance) do
        ApplyMate::Client::ProxyMate::Clearance.new(cookie: 'cf_clearance=tok', user_agent: 'Mozilla/5.0 Firefox/147.0',
                                                    impersonate: 'firefox147')
      end
      let(:client) { described_class.new(proxy: 'socks5h://1.2.3.4:1080', clearance: clearance) }

      it 'uses the fingerprint and User-Agent the token is bound to' do
        stub_curl
        client.get('https://jobs.dou.ua/vacancies/')

        expect(@captured[@captured.index('--impersonate') + 1]).to eq('firefox147')
        expect(@captured).to include('-H', 'User-Agent: Mozilla/5.0 Firefox/147.0')
        expect(@captured).to include('-H', 'Cookie: cf_clearance=tok')
      end

      it "appends the token to the scraper's own cookie in a single Cookie header" do
        stub_curl
        client.post('https://x', body: 'count=0', headers: { 'Cookie' => 'csrftoken=abc', 'User-Agent' => 'other' })

        expect(@captured.each_cons(2).select { |flag, _| flag == '-H' }.map(&:last))
          .to contain_exactly('Cookie: csrftoken=abc; cf_clearance=tok', 'User-Agent: Mozilla/5.0 Firefox/147.0')
      end
    end

    it 'reports the URL after redirects as final_url' do
      stub_curl(final_url: 'https://djinni.co/jobs/')

      expect(described_class.new.get('https://djinni.co/jobs/?page=999').final_url).to eq('https://djinni.co/jobs/')
    end

    it 'raises RequestError with what curl said when it fails (dead proxy / timeout)' do
      stub_curl(exitcode: 28, errormsg: 'Operation timed out after 10001 milliseconds with 0 bytes received')

      expect { described_class.new(proxy: 'http://dead:1', connect_timeout: 4).get('https://x') }
        .to raise_error(described_class::RequestError,
                        'curl-impersonate failed (exit 28): Operation timed out after 10001 milliseconds with 0 bytes received')
    end

    it 'raises BinaryError, not a proxy failure, when curl-impersonate cannot be started' do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT, 'curl-impersonate')

      expect { described_class.new.get('https://x') }.to raise_error(described_class::BinaryError, /install-curl-impersonate/)
    end

    # curl writes no -w output when it rejects an option, cannot load, or is killed (OOM)
    # mid-transfer: that must not read as an HTTP 0 page or a dead proxy.
    it 'raises BinaryError when curl exits without its write-out' do
      status = instance_double(Process::Status, success?: false, exitstatus: nil, termsig: 9)
      allow(Open3).to receive(:capture3).and_return([ '', 'Killed', status ])

      expect { described_class.new.get('https://x') }.to raise_error(described_class::BinaryError, /no result.*signal 9/)
    end

    it 'gives the process slot back after every request, failed ones included' do
      stub_curl(exitcode: 7, errormsg: 'Could not connect to server')
      (described_class::MAX_PROCESSES + 1).times do
        expect { described_class.new.get('https://x') }.to raise_error(described_class::RequestError)
      end

      expect(described_class::SLOTS.size).to eq(described_class::MAX_PROCESSES)
    end

    it 'runs at most MAX_PROCESSES curl subprocesses at once' do
      stub_const("#{described_class}::SLOTS", Thread::Queue.new.tap { |queue| 2.times { queue << true } })
      running = 0
      peak    = 0
      allow(Open3).to receive(:capture3) do |*args|
        running += 1
        peak = [ peak, running ].max
        sleep(0.01) # yields to the reactor
        running -= 1
        File.write(args[args.index('-o') + 1], '')
        [ "200\n0\n0.01\n#{args.last}\n", '', instance_double(Process::Status, success?: true) ]
      end

      Sync { 5.times.map { Async { described_class.new.get('https://x') } }.each(&:wait) }

      expect(peak).to eq(2)
    end

    it 'pins the release bin/install-curl-impersonate installs' do
      expect(described_class::RELEASE).to eq(Rails.root.join('bin/install-curl-impersonate').read[/CURL_IMPERSONATE_VERSION:-(v[\d.]+)/, 1])
      expect(described_class::RELEASE).to match(/\Av\d+\.\d+\.\d+\z/)
    end
  end

  describe '#post' do
    it 'sends POST with the body from a file via --data-binary' do
      stub_curl(code: 201)
      response = described_class.new.post('https://x', body: 'count=40')

      expect(@captured).to include('-X', 'POST')
      # The body goes through a file (@path), never argv — a multipart payload carries
      # a binary PDF that would exceed ARG_MAX and lose NUL bytes as an argument.
      expect(@captured[@captured.index('--data-binary') + 1]).to start_with('@')
      expect(@request_body).to eq('count=40')
      expect(response.status).to eq(201)
    end
  end
end
