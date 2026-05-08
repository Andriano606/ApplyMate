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
