# Proxy Validation

## Proxy model — fail tracking

`Proxy` tracks how many consecutive times a proxy has failed. When the count reaches `MAX_FAIL_COUNT` the proxy is deleted automatically.

```ruby
proxy.increment_fail!   # on DeadProxyError — increments or destroys
proxy.reset_fail!       # on success — zeroes counter (no-op if already 0)
```

`reset_fail!` only issues a DB write when `fail_count > 0`, so calling it on every successful request is cheap.

### Call order matters

`increment_fail!` must be called **before** `release_proxy` and before setting `proxy = nil`. After those two steps the reference is gone or the record may be destroyed:

```ruby
rescue ApplyMate::Client::Base::DeadProxyError
  proxy&.increment_fail!          # ← while proxy reference is still live
  release_proxy(proxy, in_use_proxy_ids)
  proxy = nil
  retry
```

### Guard `mark_used!` against destroyed records

`increment_fail!` may destroy the proxy row. Any code that calls `mark_used!` afterward must check `proxy.destroyed?` first:

```ruby
def release_proxy(proxy, in_use_proxy_ids)
  return unless proxy
  in_use_proxy_ids.delete(proxy.id)
  proxy.mark_used! unless proxy.destroyed?
end
```

Without the guard, `update_column` on a destroyed record raises `ActiveRecord::RecordNotFound`.

## Class structure

| Class | Responsibility |
|-------|---------------|
| `Proxy::Job::FetchProxies` | Orchestrator — calls the three operations in sequence |
| `Proxy::Operation::FetchCandidates` | Downloads public proxy lists, parses candidates |
| `Proxy::Operation::ValidateCandidates` | Async fiber validation (Phase 1 + Phase 2); receives `candidates:` |
| `Proxy::Operation::PersistProxies` | Upserts valid proxies; receives `proxies:` |

## `https` in proxy lists means HTTP CONNECT, not TLS

Public proxy list files named `https.txt` (e.g. from gfpcom) contain plain HTTP CONNECT proxies that have been *tested against HTTPS targets* — the proxy itself does **not** speak TLS. Storing the protocol as `https` causes tools (`curl -x https://...`, `Net::HTTP` proxy mode) to attempt a TLS handshake with the proxy server, which fails:

```
curl: (35) TLS connect error: error:0A0000C6:SSL routines::packet length too long
```

**Fix:** normalize `'https'` → `'http'` in `normalize_proxy_scheme` and in `infer_protocol_from_source_list_url`:

```ruby
def normalize_proxy_scheme(scheme)
  case scheme.to_s.downcase
  when 'https' then 'http'   # proxy list "https" = can forward HTTPS, not speaks TLS
  when 'socks5a' then 'socks5h'
  # ...
  end
end
```

Any existing `https` rows in the `proxies` table should be migrated:

```ruby
Proxy.where(protocol: 'https').update_all(protocol: 'http')
```

## Accept 2xx and 3xx when validating proxy reachability

Checking `status == 200 && body_present` rejects valid proxies when the target site redirects (e.g. `djinni.co / → 302 /hire`). A redirect proves the proxy reached the target — accept it:

```ruby
status = raw.split("\r\n", 2).first&.split(' ', 3)&.at(1).to_i
sep    = raw.index("\r\n\r\n")

# 3xx: redirect body is empty by design, status alone is sufficient proof
# 2xx: require non-empty body to rule out transparent interception
(300..399).cover?(status) || (status == 200 && sep && raw.length > sep + 4)
```

## Validation

Uses `ApplyMate::Client::AsyncHttp` with its default timeout — one client instance per candidate, constructed inside the fiber.

A proxy is accepted if **at least one of `VALIDATION_ATTEMPTS` (20) attempts passes**. Each attempt requires both:
1. `PHASE1_URL` (google.com) is reachable — confirms basic internet access
2. At least one source URI is reachable

`any?` short-circuits on the first successful attempt.

```ruby
VALIDATION_ATTEMPTS.times.any? do
  reachable?(client, PHASE1_URL) &&
    source_uris.map(&:to_s).any? { |url| reachable?(client, url) }
end
```

Accept any 2xx/3xx response. `AsyncHttp` raises `DeadProxyError` on any tunnel or I/O failure — rescue it in `reachable?` and return `false`.

Load source URIs once in `perform` before the `Async` block and pass into `validate` — never query `Source` inside a fiber:

```ruby
source_uris = Source.all.filter_map { |s| URI.parse(s.base_url) rescue nil }
valid = validate(candidates, source_uris)
```

## VALIDATION_CONCURRENCY tuning

This job is pure I/O-bound. CPU core count is irrelevant. The main constraints:

- **File descriptors** — the critical one. Each fiber holds 1–2 FDs during a probe. Docker's default soft limit is 1024, which is far too low. Fibers that can't open sockets (`Errno::EMFILE`) return nil immediately with no yield point, and a single fiber can monopolize the reactor thread while draining the entire candidate queue. Fix: add `ulimit: ["nofile=65536:65536"]` under each server role's `options:` in `deploy.staging.yml`.
- **Network throughput** — the real ceiling; stop increasing concurrency when `wall_clock` stops improving
- With `VALIDATION_TIMEOUT=3`, throughput ceiling ≈ `CONCURRENCY / 3` probes/sec

Tune by running the job with different env values and comparing `wall_clock` in the debug log:

```bash
FETCH_PROXIES_VALIDATION_CONCURRENCY=2000 bin/rails runner "Proxy::Job::FetchProxies.perform_now"
```
