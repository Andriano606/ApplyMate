# Async / Fiber Concurrency

Used in `Vacancy::Job::SyncVacancies` to run one fiber per `Source` concurrently.

## Gems

```ruby
gem 'async'      # fiber scheduler + reactor
gem 'async-http' # fiber-aware HTTP client (Async::HTTP::Internet)
```

## Pattern: fan-out job

```ruby
require 'async'

def perform
  Async do                          # outer: creates reactor, blocks thread until done
    tasks = Source.all.map do |s|
      Async do                      # inner: spawns child Task (fiber) in same reactor
        do_work(s)
      end
    end
    tasks.each(&:wait)              # parent fiber yields until each child completes
  end
end
```

- **Outer `Async do`** — creates the event loop (reactor) on the current thread. Blocks until all children finish. Only needed when called outside an existing Async context.
- **Inner `Async do`** — spawns a child `Async::Task` (fiber). All children are scheduled concurrently within the same reactor.
- **Single-threaded** — only one fiber runs at a time; switching happens on I/O yield or `sleep`.

## AsyncHttp client

`ApplyMate::Client::AsyncHttp` wraps `Async::HTTP::Internet` with the same interface as `Http` (`get`, `fetch_body`, `post`, `post_xhr`). Use it instead of `Http` inside Async fibers — `Http` uses Faraday/Net::HTTP which blocks the entire thread.

```ruby
client = ApplyMate::Client::AsyncHttp.new
# must call inside Async block; close when done:
client.close
```

### `Protocol::HTTP::Headers` gotchas

`response.headers` returns `Protocol::HTTP::Headers`, **not** a Hash. It does **not** include `Enumerable` — methods like `each_with_object`, `map`, `select` are unavailable. Use plain `each`:

```ruby
# ✅ correct
result = {}
headers.each { |k, v| result[k.to_s.downcase] ||= v.to_s }

# ❌ fails — NoMethodError
headers.each_with_object({}) { |(k, v), h| h[k] = v }
```

### Making requests

```ruby
# headers must be array of [key, value] pairs, not a hash
response = @internet.get(url, [["User-Agent", "..."]])
body     = response.read      # String — consumes and closes body stream
status   = response.status    # Integer
```

## sleep is fiber-aware

`Kernel.sleep` inside an Async fiber is intercepted by the Ruby 3+ Fiber Scheduler — it suspends the current fiber and lets others run. No manual `Fiber.yield` needed.

```ruby
sleep(rand(2..5))   # yields to scheduler; other fibers proceed during the wait
```

This means scraper polite-delay sleeps automatically interleave across sources.

## When to use vs threads

| | Async fibers | Threads |
|---|---|---|
| I/O-bound (HTTP, sleep) | ✅ ideal | works |
| CPU-bound | ❌ no gain | ✅ |
| Race conditions | none (single-thread) | need mutexes |
| ActiveRecord | safe — DB calls block fiber but don't interleave | need connection pool config |

## Async::Queue — nil-sentinel drain pattern

`Async::Queue#dequeue` blocks the fiber forever if the queue is empty. Workers must be unblocked with nil sentinels after all real items are enqueued:

```ruby
items.each { |i| queue.enqueue(i) }
CONCURRENCY.times { queue.enqueue(nil) }   # one sentinel per worker

Async do
  CONCURRENCY.times.map do
    Async do
      loop do
        item = queue.dequeue
        break unless item          # nil sentinel → exit
        process(item)
      end
    end
  end.each(&:wait)
end
```

Workers that exit early (e.g. target reached) skip `dequeue` — their unconsumed sentinels sit harmlessly in the queue.

## Fiber.blocking does NOT yield to other fibers by default

`Fiber.blocking { some_c_extension_call }` bypasses the scheduler **and blocks the entire reactor thread**. All 512 fibers stall until the block returns.

This is only safe if `IO::Event::WorkerPool` is available (check: `IO::Event.const_defined?(:WorkerPool)`). In this project it is **not** available, so `Fiber.blocking` is effectively synchronous.

**Workaround:** use raw `TCPSocket` (fiber-aware) for any blocking I/O that can be expressed as plain TCP. See the section below.

## TCPSocket is fully fiber-aware

Under Ruby 3's Async scheduler, standard `TCPSocket.new`, `sock.read`, `sock.write`, and `sock.gets` are **all** intercepted by the scheduler — the fiber suspends and other fibers run during I/O waits. No special async wrappers needed.

Use this for lightweight raw-protocol probes (CONNECT handshakes, SOCKS handshakes, custom TCP protocols) instead of `Async::HTTP::Client`:

```ruby
def probe(host, port)
  Async::Task.current.with_timeout(3) do
    sock = TCPSocket.new(host, port.to_s)
    begin
      sock.write("CONNECT target.com:443 HTTP/1.1\r\nHost: target.com:443\r\n\r\n")
      sock.gets&.split(' ', 3)&.at(1).to_i == 200
    ensure
      sock.close rescue nil
    end
  end
rescue StandardError
  false
end
```

## Async::HTTP::Client — avoid for short-lived probes

`Async::HTTP::Client` maintains a **persistent connection pool**. When used for one-shot CONNECT tunnels, `client.close` emits:

```
warn: Waiting for Async::HTTP::Protocol::HTTP pool to drain: #<Async::Pool::Controller(1/∞) 1/1*/1>
```

Root cause: the CONNECT response body is a streaming `Body::Pipe` (the tunnel itself). Closing `proxied` doesn't synchronously signal `client`'s pool — the pool sees the connection as busy and waits.

**Rule:** use `Async::HTTP::Client` only when you need keep-alive across multiple requests to the same host. For one-shot probes use a bare `TCPSocket` instead.

## Async::HTTP::Proxy::Client — module, not class

`Async::HTTP::Proxy::Client` is a **module** prepended to `Async::HTTP::Client`, not a standalone class. `Async::HTTP::Proxy::Client.new` does not exist.

```ruby
# ❌ wrong
proxy_client = Async::HTTP::Proxy::Client.new(proxy_endpoint)

# ✅ correct — Proxy::Client methods are prepended to every Client instance
Async::HTTP::Client.open(proxy_endpoint) do |client|
  proxied = client.proxied_client(target_endpoint)   # returns a new Client
  proxied.close                                       # Client#close exists
end
```

## OpenSSL::SSL::SSLSocket is fiber-safe in Ruby 3

`OpenSSL::SSL::SSLSocket#connect` internally loops over `connect_nonblock` with `IO.select`. In Ruby 3.1+, `IO.select` goes through the fiber scheduler, so TLS handshakes yield to other fibers automatically — no `Fiber.blocking` needed.

To do TLS over a raw tunnel socket inside an Async fiber:

```ruby
sock = TCPSocket.new(host, port.to_s)      # fiber-aware
ssl  = OpenSSL::SSL::SSLSocket.new(sock)
ssl.hostname   = host                       # SNI
ssl.sync_close = true                       # ssl.close also closes sock
ssl.connect                                 # fiber-yields during handshake
ssl.write("GET / HTTP/1.0\r\nHost: #{host}\r\n\r\n")
raw = ssl.read(4096)
ssl.close                                   # closes sock too
```

`sync_close = true` ensures the underlying `TCPSocket` is closed when the `SSLSocket` is closed — avoids double-close management.

## Reusing a SOCKS/HTTP CONNECT tunnel socket for TLS

After a SOCKS or HTTP CONNECT handshake succeeds, the raw `TCPSocket` is a transparent byte pipe to the target. Wrap it directly in `OpenSSL::SSL::SSLSocket` to layer TLS on top:

```ruby
# 1. Establish tunnel (SOCKS5 example)
sock = TCPSocket.new(proxy_host, proxy_port.to_s)
return unless socks5_tunnel_open?(sock, target_host, 443)

# 2. Layer TLS — sock is now a pipe to target_host:443
ssl = OpenSSL::SSL::SSLSocket.new(sock)
ssl.hostname   = target_host
ssl.sync_close = true
ssl.connect

# 3. Send HTTP over TLS
ssl.write("GET / HTTP/1.1\r\nHost: #{target_host}\r\nConnection: close\r\n\r\n")
raw = ssl.read(4096)
ssl.close
```

This pattern lets you parameterize SOCKS/HTTP-CONNECT tunnel methods with `host`/`port` and reuse them for both quick handshake probes (default = test host) and real-content validation (target = actual site).

## Async::HTTP::Endpoint#address crashes before connect

`Async::HTTP::Endpoint.parse("http://host:port").address` raises `NoMethodError` because `IO::Endpoint::HostEndpoint` has no `address` until a connection is resolved. Use `.url.to_s` for logging:

```ruby
# ❌ NoMethodError on HostEndpoint
proxy_endpoint.address.to_s

# ✅
proxy_endpoint.url.to_s
```
