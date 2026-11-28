# Async / Fiber Concurrency

Used in `Vacancy::Job::SyncVacancies` to run one fiber per `Source` concurrently.

## Gems

```ruby
gem 'async' # fiber scheduler + reactor (Async, Async::Barrier, Async::Semaphore)
```

There is no Ruby HTTP client gem in the pipeline: scrapers go through curl-impersonate
subprocesses (`ApplyMate::Client::ImpersonateHttp`), ProxyMate through plain `Net::HTTP`.

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

## HTTP inside the reactor

**Scrapers — `ApplyMate::Client::ImpersonateHttp`.** One `Open3.capture3` curl-impersonate
subprocess per request. The reactor hooks `process_wait` and the pipes, so a fiber **yields**
while its curl runs (8 concurrent requests: 0.07 s vs 0.46 s sequential). Fan-out is capped in
the client, process-wide: `ImpersonateHttp::MAX_PROCESSES` (ENV `CURL_IMPERSONATE_MAX_PROCESSES`,
default 64 — 2 sources × 32 sync fibers on the 4-core Pi 5) slots in a `Thread::Queue` of tokens
(`SLOTS`). `Thread::Queue#pop` goes through the fiber scheduler inside a reactor (the fiber waits,
others run) and blocks plainly outside one, and is thread-safe — `Async::Semaphore` would be
neither. A slot is given back in `ensure`, failed requests included.

**ProxyMate — `ApplyMate::Client::ProxyMate`.** `Net::HTTP` does **not** block the reactor on
Ruby 3.4 + async 2.x: its socket waits, DNS and `Timeout.timeout` go through the fiber scheduler
(measured: 3 concurrent 1-second requests finish in 1.0 s with a ticker fiber still running). The
client relies on this — it is plain `Net::HTTP` (so WebMock can stub it) called from worker
fibers when a pool refills, and outside any reactor for the run-level meta lookup and the pool
seeds.

### Failure behavior

Neither client retries. `ImpersonateHttp` raises `RequestError` (message: curl's exit code and
error text) when curl fails and `BinaryError` when the binary cannot start; the scraper's
`via_proxy` turns the first (and 429/5xx/Cloudflare pages) into `DeadProxyError`, lets the second
through. Retrying on another proxy is the sync worker's job:

```ruby
rescue ApplyMate::Scraper::Base::DeadProxyError
  stats.dead!        # counted for dead_proxies
  pool.drop(proxy)   # out of the pool until its next round; nothing reported to ProxyMate
  proxy = nil
  retry
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
pages_queue  = (1..MAX_PAGES).to_a     # plain Array — safe, fibers don't truly interleave
external_ids = Concurrent::Array.new   # written from N fibers concurrently
```

`Array`/`Set`/`Hash` are safe for `pages_queue` and the pool's own state because Async fibers are single-threaded — switching only happens at I/O yields. Use `Concurrent::Array` only for collections written from truly parallel workers.

### Proxy acquire / release

Proxies are not rows: `Vacancy::Operation::SyncVacancies::ProxyPool` holds the
`ApplyMate::Client::ProxyMate::Proxy` value objects ProxyMate handed out for the source and
rotates them in memory — `acquire` (nil when none is ready), `release(proxy)` after a use
(`release(proxy, ok: false)` after an unexpected error: not a successful use), `drop(proxy)` after
a `DeadProxyError` — with no DB access. Use limit, ProxyMate session, rounds and termination:
`.ai/docs/sync_vacancies.md`.

### ensure + retry — proxy release rules

`ensure` runs **once** when the `begin` block exits — it does **not** run on `retry`. Use this to avoid double-release:

```ruby
loop do
  begin
    proxy = nil    # reset on each begin, including after retry
    page  = pages_queue.shift
    break unless page

    proxy = pool.acquire
    # ...
  rescue DeadProxyError
    pool.drop(proxy)
    proxy = nil          # ← ensure sees nil, skips double-release
    pages_queue.unshift(page)
    retry                # ← ensure does NOT run here
  rescue StandardError
    pool.release(proxy, ok: false)
    proxy = nil
    pages_queue.unshift(page)
    retry
  ensure
    pool.release(proxy)  # no-op if proxy is nil
  end
end
```

Initializing `proxy = nil` **inside** `begin` (not before it) resets it on `retry` without any explicit reset at the loop top. `ProxyPool#release` / `#drop` also ignore a proxy that is not checked out, so a double call cannot re-queue it twice.

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

This is only safe if `IO::Event::WorkerPool` is available (check: `IO::Event.const_defined?(:WorkerPool)`). In this project it is **not** available, so `Fiber.blocking` is effectively synchronous — keep blocking work in a subprocess (as `ImpersonateHttp` does) or on fiber-aware I/O.
