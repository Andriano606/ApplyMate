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

`ApplyMate::Client::AsyncHttp` sends HTTP/HTTPS requests through a SOCKS5 or HTTP-CONNECT proxy using raw `TCPSocket` — no `Async::HTTP::Internet` involved. It exposes the same interface as `Http` (`get`, `fetch_body`, `post`, `post_xhr`) so scrapers can swap clients transparently. Use it instead of `Http` inside Async fibers — `Http` uses Faraday/Net::HTTP which blocks the entire thread.

```ruby
# proxy: is required
client = ApplyMate::Client::AsyncHttp.new(proxy: proxy.url)
# no close method — each request manages its own socket
```

### Constructor

```ruby
ApplyMate::Client::AsyncHttp.new(timeout: 30, proxy:)
# timeout: overall request deadline in seconds (default 30)
# proxy:   proxy URL string — supports http://, https://, socks5://, socks5h://
```

The client must be called inside an `Async` block (uses `Async::Task.current.with_timeout`).

### Proxy protocols

| Scheme | Tunnel method |
|--------|--------------|
| `http`, `https` | HTTP CONNECT |
| `socks5`, `socks5h` | SOCKS5 domain-name mode (address type 0x03) |

The proxy URL scheme selects only the tunnel method. TLS to the *target* is layered separately by `SSLSocket` — an `https://` proxy URL still opens a plain TCP connection to the proxy host.

### Timeouts

| | Default | Controls |
|---|---|---|
| `CONNECT_TIMEOUT` | 5 s | `Socket.tcp` connect to the proxy host |
| `timeout:` | 30 s | `Async::Task.current.with_timeout` — entire request |

### Request / Response

All requests use HTTP/1.0 (server closes after response, no chunked-encoding parsing needed). `get` and `post` return a `Response` with `.body` (String), `.headers` (plain Hash, keys downcased), and `.status` (Integer). `fetch_body` and `post_xhr` unwrap to the body String.

```ruby
response = client.get(url)     # Response or raises DeadProxyError
response.body    # String
response.status  # Integer
response.headers # plain Hash — lowercase string keys

body = client.fetch_body(url)  # String or raises DeadProxyError
```

### Failure behavior

Any tunnel or I/O failure returns `nil` internally. `get` and `post` raise `DeadProxyError` on `nil` — callers rescue it to mark the proxy dead and retry with another proxy. The `error_handler:` keyword is accepted on all public methods for interface compatibility with `Http` but is **not used internally** — proxy failures always fail fast rather than retrying.

```ruby
rescue ApplyMate::Client::DeadProxyError
  release_proxy(proxy, in_use_proxy_ids)
  proxy = nil
  retry
```

### `Protocol::HTTP::Headers` gotchas (Async::HTTP::Internet only)

This does **not** apply to `AsyncHttp` — it returns plain Ruby hashes. It applies only if you use `Async::HTTP::Internet` directly elsewhere:

`response.headers` returns `Protocol::HTTP::Headers`, **not** a Hash. It does **not** include `Enumerable` — methods like `each_with_object`, `map`, `select` are unavailable. Use plain `each`:

```ruby
# ✅ correct
result = {}
headers.each { |k, v| result[k.to_s.downcase] ||= v.to_s }

# ❌ fails — NoMethodError
headers.each_with_object({}) { |(k, v), h| h[k] = v }
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

## Pattern: proxy rotation with concurrent fiber workers

`SyncVacancies` runs `WORKERS_PER_SOURCE` fibers per source. Each fiber loops over a shared `pages_queue`, acquires a proxy, and releases it in `ensure`. Key rules:

### Shared data structures

```ruby
pages_queue      = (1..MAX_PAGES).to_a   # plain Array — safe, fibers don't truly interleave
in_use_proxy_ids = Set.new               # tracks which proxies are held right now
external_ids     = Concurrent::Array.new # written from N fibers concurrently
```

`Array`/`Set` are safe for `pages_queue` and `in_use_proxy_ids` because Async fibers are single-threaded — switching only happens at I/O yields. Use `Concurrent::Array` only for collections written from truly parallel workers.

### Proxy acquire / release

```ruby
def acquire_proxy(in_use_proxy_ids)
  ActiveRecord::Base.connection_pool.with_connection do
    Proxy.transaction do
      proxy = Proxy.ready_for_use
                   .where.not(id: in_use_proxy_ids.to_a)
                   .lock('FOR UPDATE SKIP LOCKED')
                   .first
      if proxy
        in_use_proxy_ids << proxy.id
        proxy.mark_used!
      end
      proxy
    end
  end
end

def release_proxy(proxy, in_use_proxy_ids)
  return unless proxy
  in_use_proxy_ids.delete(proxy.id)
  return if proxy.destroyed?
  with_db { proxy.mark_used! }
end

def with_db(&block)
  ActiveRecord::Base.connection_pool.with_connection(&block)
end
```

**All DB operations inside async fibers must use `with_db` (or `connection_pool.with_connection` directly).** Without it, AR holds one connection per fiber for its entire lifetime — with 500 fibers, the pool exhausts instantly and subsequent fibers time out. `with_db` borrows a connection only for the duration of the block, then returns it immediately. Group related DB calls into one `with_db` block to minimize round-trips.

`FOR UPDATE SKIP LOCKED` prevents two fibers from grabbing the same proxy row even if both hit the DB in the same reactor tick (DB calls block the fiber but two fibers can both be waiting for connection pool slots).

### ensure + retry — proxy release rules

`ensure` runs **once** when the `begin` block exits — it does **not** run on `retry`. Use this to avoid double-release:

```ruby
loop do
  begin
    client = nil   # reset on each begin, including after retry
    proxy  = nil
    page   = pages_queue.shift
    break unless page

    proxy  = acquire_proxy(in_use_proxy_ids)
    client = Client::AsyncHttp.new(proxy: proxy.url)
    # ...
  rescue DeadProxyError
    release_proxy(proxy, in_use_proxy_ids)
    proxy = nil          # ← ensure sees nil, skips double-release
    pages_queue.unshift(page)
    retry                # ← ensure does NOT run here
  rescue StandardError
    pages_queue.unshift(page)
    break                # ← ensure runs once here with current proxy ✓
  ensure
    release_proxy(proxy, in_use_proxy_ids)   # no-op if proxy is nil
    client&.close
  end
end
```

Initializing `client = nil; proxy = nil` **inside** `begin` (not before it) ensures they reset on `retry` without any explicit reset at the loop top.

### Stop signal — confirmed last page

Don't clear the queue on the first empty result: some sites return empty pages sporadically to foil scrapers. Use a confirmation counter instead:

```ruby
last_page = { counts: Hash.new(0), boundary: nil }
```

On empty result:
```ruby
last_page[:counts][page] += 1
count = last_page[:counts][page]
if count >= LAST_PAGE_CONFIRMATIONS
  last_page[:boundary] = [last_page[:boundary], page].compact.min
  next
elsif count == 1
  # Fan-out: push 49 copies so all remaining confirmations run in parallel.
  (LAST_PAGE_CONFIRMATIONS - 1).times { pages_queue.unshift(page) }
end
# count > 1 && count < LAST_PAGE_CONFIRMATIONS: copies already in queue, do nothing
```

On each shift:
```ruby
break if last_page[:boundary] && page >= last_page[:boundary]
```

`[last_page[:boundary], page].compact.min` means later confirmations can only lower the boundary — if pages 500, 502, 504 all confirm, the boundary lands at 500. Workers that have already shifted pages ≥ boundary exit immediately without an HTTP call.

### Progress counter

Share a one-element array as a mutable counter across fibers:

```ruby
total = vacancies_queue.size
done  = [0]

# in worker, after each item is processed:
done[0] += 1
log("#{ctx(...)} #{done[0] * 100 / total}% (#{done[0]}/#{total})", color: :green)
```

Plain `[0]` is safe here — fibers are single-threaded so no true race. Use `Concurrent::AtomicFixnum` only if you ever move to real threads.

### Structured logging for concurrent fibers

When N fibers write to the same log, prefix every message with a `ctx` tag so lines can be correlated:

```ruby
def ctx(source, label, proxy = nil)
  fiber_id = Fiber.current.object_id.to_s.last(4)
  "[#{source.name}|#{label}|#{proxy&.host || '—'}|f#{fiber_id}]"
end

# usage — use "p#{page}" for page workers, vacancy.external_id for description workers
log("#{ctx(source, "p#{page}", proxy)} #{listing.size} items", color: :green)
# → [Djinni|p5|1.2.3.4|f7890] 20 items
```

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

## OpenSSL::SSL::SSLSocket — use connect_nonblock, not connect

`OpenSSL::SSL::SSLSocket#connect` internally loops over `connect_nonblock` with `IO.select`. In theory, `IO.select` goes through the fiber scheduler in Ruby 3.1+. In practice, on some Ruby/io-event/platform combinations (observed on ARM64/RPI5) it does not — `ssl.connect` blocks the reactor thread and `with_timeout` cannot fire.

**Always use `connect_nonblock` + explicit `IO.select` with a deadline.** This is correct in both cases: when the scheduler intercepts `IO.select`, the fiber yields during wait; when it does not, the OS-level `select(2)` enforces the timeout.

```ruby
def ssl_connect(ssl)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT
  loop do
    ssl.connect_nonblock
    return true
  rescue IO::WaitReadable
    remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return false if remaining <= 0
    IO.select([ssl.to_io], nil, nil, remaining) or return false
  rescue IO::WaitWritable
    remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return false if remaining <= 0
    IO.select(nil, [ssl.to_io], nil, remaining) or return false
  rescue StandardError
    return false
  end
end
```

To do TLS over a raw tunnel socket inside an Async fiber:

```ruby
sock = TCPSocket.new(host, port.to_s)      # fiber-aware
ssl  = OpenSSL::SSL::SSLSocket.new(sock)
ssl.hostname   = host                       # SNI
ssl.sync_close = true                       # ssl.close also closes sock
ssl_connect(ssl)                            # safe on all platforms
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
