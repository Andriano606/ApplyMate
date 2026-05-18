# frozen_string_literal: true

require 'rails_helper'
require 'socket'

RSpec.describe ApplyMate::Client::AsyncHttp do
  # ── Test TCP server ──────────────────────────────────────────────────────────
  #
  # Spins up a real TCPServer on a random port. Each connection is handled in
  # its own thread so redirect chains (one connection per hop) work concurrently.
  # The server speaks HTTP/1.0 and closes the connection after every response —
  # mirroring what the client expects from real upstreams.
  class TestServer
    attr_reader :requests

    def initialize
      @server    = TCPServer.new('127.0.0.1', 0)
      @requests  = []
      @responses = []
      @mutex     = Mutex.new
      @thread    = Thread.new { run_loop }
    end

    def port = @server.addr[1]
    def url(path = '/') = "http://127.0.0.1:#{port}#{path}"

    def queue(status: 200, headers: {}, body: '', delay: nil)
      @mutex.synchronize { @responses << { status: status, headers: headers, body: body, delay: delay } }
    end

    def stop
      return if @stopped
      @stopped = true
      @server.close rescue nil
      @thread.join(2)
    end

    private

    def run_loop
      loop { Thread.new(@server.accept) { |sock| handle(sock) } }
    rescue IOError, Errno::EBADF, Errno::ENOTSOCK
      # server closed, exit gracefully
    end

    def handle(sock)
      request = read_request(sock)
      @mutex.synchronize { @requests << request }
      response = @mutex.synchronize { @responses.shift } || default_response
      sleep(response[:delay]) if response[:delay]
      write_response(sock, response)
    rescue StandardError
      # client disconnected mid-conversation — ignore
    ensure
      sock.close rescue nil
    end

    def default_response = { status: 200, headers: {}, body: '' }

    def read_request(sock)
      lines = []
      while (line = sock.gets) && line != "\r\n"
        lines << line.chomp
      end
      request_line = lines.shift.to_s
      headers = lines.each_with_object({}) do |line, h|
        k, v = line.split(': ', 2)
        h[k.downcase] = v if k && v
      end
      body = nil
      if (cl = headers['content-length']&.to_i) && cl.positive?
        body = sock.read(cl)
      end
      { request_line: request_line, headers: headers, body: body }
    end

    def write_response(sock, r)
      sock.write "HTTP/1.0 #{r[:status]} Status\r\n"
      r[:headers].each { |k, v| sock.write "#{k}: #{v}\r\n" }
      sock.write "Content-Length: #{r[:body].bytesize}\r\n"
      sock.write "Connection: close\r\n"
      sock.write "\r\n"
      sock.write r[:body]
    end
  end

  let(:server) { TestServer.new }
  let(:no_retry_handler) { ApplyMate::Client::ErrorHandler.new(max_retries: 0, base_delay: 0) }

  before do
    # Eliminate real backoff sleeps inside ErrorHandler#handle_retry.
    allow_any_instance_of(ApplyMate::Client::ErrorHandler).to receive(:sleep)
  end

  after { server.stop }

  # ── #initialize ──────────────────────────────────────────────────────────────
  describe '#initialize' do
    it 'defaults timeout to 15 seconds' do
      client = described_class.new
      expect(client.instance_variable_get(:@timeout)).to eq(15)
    end

    it 'defaults proxy to nil (direct connection)' do
      client = described_class.new
      expect(client.instance_variable_get(:@proxy_uri)).to be_nil
    end

    it 'parses an HTTP proxy URL into URI' do
      client = described_class.new(proxy: 'http://10.0.0.1:8080')
      proxy  = client.instance_variable_get(:@proxy_uri)
      expect(proxy.host).to eq('10.0.0.1')
      expect(proxy.scheme).to eq('http')
    end

    it 'parses a SOCKS5 proxy URL into URI' do
      client = described_class.new(proxy: 'socks5h://1.2.3.4:1080')
      proxy  = client.instance_variable_get(:@proxy_uri)
      expect(proxy.scheme).to eq('socks5h')
    end

    it 'accepts a custom error_handler' do
      handler = ApplyMate::Client::ErrorHandler.new(max_retries: 42)
      client  = described_class.new(error_handler: handler)
      expect(client.instance_variable_get(:@error_handler)).to eq(handler)
    end

    it 'falls back to Base.default_error_handler when none provided' do
      client = described_class.new
      expect(client.instance_variable_get(:@error_handler))
        .to be_a(ApplyMate::Client::ErrorHandler)
    end
  end

  # ── #get ─────────────────────────────────────────────────────────────────────
  describe '#get' do
    let(:client) { described_class.new(timeout: 5, error_handler: no_retry_handler) }

    it 'returns a Response with body, status, headers, and final_url on 200' do
      server.queue(status: 200, body: 'hello', headers: { 'X-Server' => 'test' })
      response = client.get(server.url('/foo'))

      expect(response).to be_a(ApplyMate::Client::Base::Response)
      expect(response.status).to eq(200)
      expect(response.body).to eq('hello')
      expect(response.headers['x-server']).to eq('test')
      expect(response.final_url).to eq(server.url('/foo'))
      expect(response.success?).to be true
    end

    it 'sends the GET method and request path' do
      server.queue(status: 200, body: 'ok')
      client.get(server.url('/path/to/thing?q=1'))

      expect(server.requests.last[:request_line]).to eq('GET /path/to/thing?q=1 HTTP/1.0')
    end

    it 'sends the default User-Agent header' do
      server.queue(status: 200, body: '')
      client.get(server.url)

      expect(server.requests.last[:headers]['user-agent'])
        .to eq(ApplyMate::Client::Base::USER_AGENT)
    end

    it 'merges custom headers with the User-Agent' do
      server.queue(status: 200, body: '')
      client.get(server.url, headers: { 'X-Custom' => 'value', 'Cookie' => 'a=1' })

      headers = server.requests.last[:headers]
      expect(headers['x-custom']).to eq('value')
      expect(headers['cookie']).to eq('a=1')
      expect(headers['user-agent']).to eq(ApplyMate::Client::Base::USER_AGENT)
    end

    it 'sends the Host header derived from the URL' do
      server.queue(status: 200, body: '')
      client.get(server.url)

      expect(server.requests.last[:headers]['host']).to eq('127.0.0.1')
    end

    it 'returns Response with success? false for 4xx without retrying' do
      server.queue(status: 404, body: 'not found')
      response = client.get(server.url)

      expect(response.status).to eq(404)
      expect(response.success?).to be false
      expect(server.requests.size).to eq(1)
    end

    it 'returns Response for non-retryable 5xx without retrying' do
      server.queue(status: 500, body: 'oops')
      response = client.get(server.url)

      expect(response.status).to eq(500)
      expect(server.requests.size).to eq(1)
    end
  end

  # ── #post ────────────────────────────────────────────────────────────────────
  describe '#post' do
    let(:client) { described_class.new(timeout: 5, error_handler: no_retry_handler) }

    it 'sends POST method with the body' do
      server.queue(status: 200, body: 'ok')
      client.post(server.url('/submit'), body: 'name=jane&age=30')

      expect(server.requests.last[:request_line]).to eq('POST /submit HTTP/1.0')
      expect(server.requests.last[:body]).to eq('name=jane&age=30')
    end

    it 'sets Content-Length to the body bytesize' do
      server.queue(status: 200, body: '')
      payload = 'привіт' # multi-byte UTF-8
      client.post(server.url, body: payload)

      expect(server.requests.last[:headers]['content-length']).to eq(payload.bytesize.to_s)
    end

    it 'returns Response on success' do
      server.queue(status: 201, body: 'created')
      response = client.post(server.url, body: 'x=1')

      expect(response.status).to eq(201)
      expect(response.body).to eq('created')
    end
  end

  # ── #post_multipart ──────────────────────────────────────────────────────────
  describe '#post_multipart' do
    let(:client) { described_class.new(timeout: 5, error_handler: no_retry_handler) }

    it 'sets multipart/form-data Content-Type with boundary' do
      server.queue(status: 200, body: '')
      client.post_multipart(server.url, payload: { 'field' => 'value' })

      content_type = server.requests.last[:headers]['content-type']
      expect(content_type).to match(%r{\Amultipart/form-data; boundary=----RubyMultipart[a-f0-9]+\z})
    end

    it 'includes plain string fields with Content-Disposition' do
      server.queue(status: 200, body: '')
      client.post_multipart(server.url, payload: { 'name' => 'Jane', 'email' => 'jane@example.com' })

      body = server.requests.last[:body]
      expect(body).to include('Content-Disposition: form-data; name="name"')
      expect(body).to include("\r\n\r\nJane\r\n")
      expect(body).to include('Content-Disposition: form-data; name="email"')
      expect(body).to include("\r\n\r\njane@example.com\r\n")
    end

    it 'includes Faraday::Multipart::FilePart-style file parts' do
      file_part = Faraday::Multipart::FilePart.new(StringIO.new('PDF-CONTENT'), 'application/pdf', 'cv.pdf')
      server.queue(status: 200, body: '')
      client.post_multipart(server.url, payload: { 'cv_file' => file_part })

      body = server.requests.last[:body]
      expect(body).to include('Content-Disposition: form-data; name="cv_file"; filename="cv.pdf"')
      expect(body).to include('Content-Type: application/pdf')
      expect(body).to include('PDF-CONTENT')
    end

    it 'terminates the body with the closing boundary' do
      server.queue(status: 200, body: '')
      client.post_multipart(server.url, payload: { 'a' => '1' })

      content_type = server.requests.last[:headers]['content-type']
      boundary     = content_type[/boundary=(.+)\z/, 1]
      expect(server.requests.last[:body]).to end_with("--#{boundary}--\r\n")
    end

    it 'does NOT follow redirects (returns the 3xx response as-is)' do
      server.queue(status: 302, headers: { 'Location' => '/thank-you' }, body: '')
      # Only ONE response queued — if it followed, it would hang on the second connection.
      response = client.post_multipart(server.url('/apply'), payload: { 'a' => '1' })

      expect(response.status).to eq(302)
      expect(response.headers['location']).to eq('/thank-you')
      expect(server.requests.size).to eq(1)
    end

    it 'goes through the error_handler and retries on 502' do
      handler = ApplyMate::Client::ErrorHandler.new(max_retries: 3, base_delay: 0)
      client  = described_class.new(timeout: 5, error_handler: handler)
      server.queue(status: 502, body: 'bad gateway')
      server.queue(status: 200, body: 'ok')

      response = client.post_multipart(server.url, payload: { 'a' => '1' })

      expect(response.status).to eq(200)
      expect(server.requests.size).to eq(2)
    end
  end

  # ── Redirects ────────────────────────────────────────────────────────────────
  describe 'redirect handling' do
    let(:client) { described_class.new(timeout: 5, error_handler: no_retry_handler) }

    it 'follows a 301 and switches to GET (drops body)' do
      server.queue(status: 301, headers: { 'Location' => '/new' }, body: '')
      server.queue(status: 200, body: 'final')

      response = client.post(server.url('/old'), body: 'x=1')

      expect(response.status).to eq(200)
      expect(response.body).to eq('final')
      expect(server.requests.size).to eq(2)
      expect(server.requests.last[:request_line]).to start_with('GET /new')
      expect(server.requests.last[:body]).to be_nil
    end

    it 'follows a 302 and switches to GET' do
      server.queue(status: 302, headers: { 'Location' => '/elsewhere' }, body: '')
      server.queue(status: 200, body: 'ok')

      response = client.post(server.url, body: 'x=1')
      expect(response.status).to eq(200)
      expect(server.requests.last[:request_line]).to start_with('GET /elsewhere')
    end

    it 'preserves method and body on 307' do
      server.queue(status: 307, headers: { 'Location' => '/keep' }, body: '')
      server.queue(status: 200, body: 'preserved')

      response = client.post(server.url('/old'), body: 'keep=this')

      expect(response.status).to eq(200)
      expect(server.requests.last[:request_line]).to start_with('POST /keep')
      expect(server.requests.last[:body]).to eq('keep=this')
    end

    it 'preserves method and body on 308' do
      server.queue(status: 308, headers: { 'Location' => '/keep' }, body: '')
      server.queue(status: 200, body: '')

      client.post(server.url, body: 'still=here')
      expect(server.requests.last[:request_line]).to start_with('POST /keep')
      expect(server.requests.last[:body]).to eq('still=here')
    end

    it 'updates final_url to the URL of the final response' do
      server.queue(status: 302, headers: { 'Location' => '/new' }, body: '')
      server.queue(status: 200, body: 'final')

      response = client.get(server.url('/old'))
      expect(response.final_url).to eq(server.url('/new'))
    end

    it 'follows up to MAX_REDIRECTS hops' do
      5.times { |i| server.queue(status: 302, headers: { 'Location' => "/h#{i + 1}" }, body: '') }
      server.queue(status: 200, body: 'arrived')

      response = client.get(server.url('/start'))

      expect(response.status).to eq(200)
      expect(response.body).to eq('arrived')
      expect(server.requests.size).to eq(6) # initial + 5 redirects
    end

    it 'stops following after MAX_REDIRECTS and returns the last 3xx response' do
      (described_class::MAX_REDIRECTS + 2).times do |i|
        server.queue(status: 302, headers: { 'Location' => "/h#{i + 1}" }, body: '')
      end

      response = client.get(server.url('/start'))

      expect(response.status).to eq(302)
      expect(server.requests.size).to eq(described_class::MAX_REDIRECTS + 1)
    end

    it 'returns the 3xx response as-is when follow_redirects: false' do
      server.queue(status: 302, headers: { 'Location' => '/new' }, body: '')

      response = client.get(server.url('/old'), follow_redirects: false)

      expect(response.status).to eq(302)
      expect(response.headers['location']).to eq('/new')
      expect(response.final_url).to eq(server.url('/old'))
      expect(server.requests.size).to eq(1)
    end

    it 'returns the response unchanged when follow_redirects: false and no redirect happens' do
      server.queue(status: 200, body: 'direct')

      response = client.get(server.url('/x'), follow_redirects: false)

      expect(response.body).to eq('direct')
      expect(response.final_url).to eq(server.url('/x'))
    end
  end

  # ── Error handling ───────────────────────────────────────────────────────────
  describe 'error handling' do
    it 'raises DeadProxyError when the connection is refused' do
      dead_url = server.url('/anything')
      server.stop
      sleep 0.05 # let the OS release the port
      client = described_class.new(timeout: 2, error_handler: no_retry_handler)

      expect { client.get(dead_url) }
        .to raise_error(ApplyMate::Client::Base::DeadProxyError, /Connection failed/)
    end

    it 'raises DeadProxyError when the upstream is slower than @timeout' do
      server.queue(status: 200, body: 'late', delay: 1.5)
      client = described_class.new(timeout: 0.3, error_handler: no_retry_handler)

      expect { client.get(server.url) }
        .to raise_error(ApplyMate::Client::Base::DeadProxyError)
    end

    it 'retries on 502 and returns the eventual successful Response' do
      server.queue(status: 502, body: 'bad gateway')
      server.queue(status: 502, body: 'bad gateway')
      server.queue(status: 200, body: 'ok')

      handler = ApplyMate::Client::ErrorHandler.new(max_retries: 3, base_delay: 0)
      client  = described_class.new(timeout: 5, error_handler: handler)

      response = client.get(server.url)
      expect(response.status).to eq(200)
      expect(server.requests.size).to eq(3)
    end

    it 'retries on 503 and 504 the same way' do
      server.queue(status: 503, body: '')
      server.queue(status: 504, body: '')
      server.queue(status: 200, body: 'ok')

      handler = ApplyMate::Client::ErrorHandler.new(max_retries: 3, base_delay: 0)
      client  = described_class.new(timeout: 5, error_handler: handler)

      response = client.get(server.url)
      expect(response.status).to eq(200)
    end

    it 'raises AttemptsExhaustedError after max_retries on persistent 502' do
      6.times { server.queue(status: 502, body: '') }
      handler = ApplyMate::Client::ErrorHandler.new(max_retries: 2, base_delay: 0)
      client  = described_class.new(timeout: 5, error_handler: handler)

      expect { client.get(server.url) }
        .to raise_error(ApplyMate::Client::ErrorHandler::AttemptsExhaustedError, /Final failure after 2 retries/)
      expect(server.requests.size).to eq(3) # 1 initial + 2 retries
    end

    it 'does NOT retry on 500 (not in RETRYABLE_STATUSES)' do
      server.queue(status: 500, body: 'oops')
      handler = ApplyMate::Client::ErrorHandler.new(max_retries: 5, base_delay: 0)
      client  = described_class.new(timeout: 5, error_handler: handler)

      response = client.get(server.url)
      expect(response.status).to eq(500)
      expect(server.requests.size).to eq(1)
    end

    it 'does NOT retry on 4xx' do
      server.queue(status: 429, body: 'too many')
      handler = ApplyMate::Client::ErrorHandler.new(max_retries: 5, base_delay: 0)
      client  = described_class.new(timeout: 5, error_handler: handler)

      response = client.get(server.url)
      expect(response.status).to eq(429)
      expect(server.requests.size).to eq(1)
    end
  end

  # ── Async context handling ───────────────────────────────────────────────────
  describe 'Async context' do
    let(:client) { described_class.new(timeout: 5, error_handler: no_retry_handler) }

    it 'works outside an Async context (wraps in Sync internally)' do
      server.queue(status: 200, body: 'sync ok')
      expect(Async::Task.current?).to be_nil

      response = client.get(server.url)
      expect(response.body).to eq('sync ok')
    end

    it 'works inside an Async block (reuses the current task)' do
      server.queue(status: 200, body: 'async ok')

      response = Sync do
        expect(Async::Task.current?).not_to be_nil
        client.get(server.url)
      end

      expect(response.body).to eq('async ok')
    end
  end
end
