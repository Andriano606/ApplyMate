# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::ImpersonateHttp do
  # Stubs the curl-impersonate subprocess: writes the body/header files curl would
  # have written (paths taken from the -o/-D args) and returns the -w http_code on stdout.
  def stub_curl(body: '<html>ok</html>', headers: "HTTP/1.1 200 OK\r\n", code: 200, success: true)
    allow(Open3).to receive(:capture3) do |*args|
      @captured = args
      File.write(args[args.index('-o') + 1], body)
      File.write(args[args.index('-D') + 1], headers)
      status = instance_double(Process::Status, success?: success, exitstatus: success ? 0 : 28)
      [ code.to_s, success ? '' : 'curl: (28) timed out', status ]
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

    it 'invokes the Chrome-impersonation binary, follows redirects, and targets the URL' do
      stub_curl
      described_class.new.get('https://jobs.dou.ua/vacancies/')

      expect(@captured.first).to eq(described_class::BINARY)
      expect(@captured).to include('-L')
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

    it 'raises RequestError when curl fails (dead proxy / timeout)' do
      stub_curl(success: false)

      expect { described_class.new(proxy: 'http://dead:1').get('https://x') }
        .to raise_error(described_class::RequestError, /curl-impersonate failed/)
    end
  end

  describe '#post' do
    it 'sends POST with the body via --data-binary' do
      stub_curl(code: 201)
      response = described_class.new.post('https://x', body: 'count=40')

      expect(@captured).to include('-X', 'POST')
      expect(@captured[@captured.index('--data-binary') + 1]).to eq('count=40')
      expect(response.status).to eq(201)
    end
  end
end
