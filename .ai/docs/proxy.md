# Proxy Validation

## Per-source stats (`proxy_source_stats`) — current model

A proxy that works for one site is often blocked on another (Dou's anti-scraping is
aggressive), so reliability is tracked **per (proxy, source)**, not globally.

- **Table `proxy_source_stats`** — one row per `(proxy_id, source_id)` (unique index)
  with `success_count`, `fail_count`, `failed_at`, `reliability`. Model:
  `ProxySourceStat` (`ready_for_use` / `by_reliability` scopes, `reliability_for`).
- **`Proxy::Operation::Validate`** — probes a batch of proxies against **each** source's
  `base_url`, **using that source's own client** (`Scraper.http_client_class`: Cloudflare
  sources like Dou use `ImpersonateHttp`, others `AsyncHttp`), and accepts only **2xx/3xx**.
  Upserts the per-source result (reachable → `success_count += 1`, else `fail_count += 1`).
  Scope `:untested` grows the pool; `:working` refreshes. Run recurringly via
  `Proxy::Job::Validate` (`every 5 minutes`). Impersonate probes are capped at
  `IMPERSONATE_CONCURRENCY` (curl subprocess per probe — avoids a fork storm).
- **`Vacancy::Operation::SyncVacancies`** — each source has its own in-memory pool seeded
  from **its** `proxy_source_stats` (working, by reliability), validated live at seed with
  the same per-source client, and records successes/fails back per source. See
  `.ai/docs/sync_vacancies.md`.
- The same proxy can appear in several sources' pools with independent stats and
  independent burst budgets.

> **Why per-source + 2xx/3xx:** a proxy alive for one site is often blocked on another,
> and Cloudflare returns 403 ("Just a moment…") to a proxy IP whose TLS fingerprint
> isn't a real browser's. Validating each source's `base_url` with its real client (Chrome
> TLS via `ImpersonateHttp` for Dou) and accepting only 2xx/3xx makes "working" mean
> "actually scrape-usable", not just "responded".

The legacy global stat columns on `proxies` (`success_count`, `fail_count`,
`reliability`, `failed_at`) are no longer written by the sync/validation pipeline —
per-source stats supersede them.

## Proxy model — fail tracking and success scoring (legacy global)

`Proxy` tracks consecutive failures and recent successes (5-minute sliding window).

```ruby
proxy.increment_fail!        # on DeadProxyError — increments fail_count or destroys; resets success window
proxy.increment_succeeded!   # on success — resets fail_count, increments recent_success_count
```

`increment_succeeded!` always issues a DB write (updates the success window counter on every success).

### Success window — `recent_success_count` / `recent_success_window_start`

`increment_succeeded!` maintains a 5-minute sliding window:
- If `recent_success_window_start` is within the last 5 minutes → increments `recent_success_count`.
- Otherwise → resets `recent_success_count` to 1 and starts a new window.

`increment_fail!` resets both columns to `0` / `nil` — a failing proxy loses its priority status immediately.

`ready_for_use` orders by active-window score first, then by `last_used_at`:

```sql
CASE WHEN recent_success_window_start > NOW() - interval '5 minutes'
     THEN recent_success_count ELSE 0
END DESC, last_used_at ASC NULLS FIRST
```

Proxies with more recent successes are acquired first; proxies with expired or no window fall back to round-robin.

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

- **RAM** — each fiber carries stack + an `AsyncHttp` client + local state. Valid proxies that hit `sleep(60)` between attempts keep all of that alive for minutes. Default is 200 (safe RAM, ~40–60 MB for fibers). Raise only after setting the FD limit below.
- **File descriptors** — the critical one. Each fiber holds 1–2 FDs during a probe. Docker's default soft limit is 1024, which is far too low. Fibers that can't open sockets (`Errno::EMFILE`) return nil immediately with no yield point, and a single fiber can monopolize the reactor thread while draining the entire candidate queue. Fix: add `ulimit: ["nofile=65536:65536"]` under each server role's `options:` in `deploy.staging.yml`.
- **Network throughput** — the real ceiling; stop increasing concurrency when `wall_clock` stops improving
- With AsyncHttp's default 30 s timeout, throughput ceiling ≈ `CONCURRENCY / 30` probes/sec

Tune by running the job with different env values and comparing `wall_clock` in the debug log:

```bash
FETCH_PROXIES_VALIDATION_CONCURRENCY=500 bin/rails runner "Proxy::Job::FetchProxies.perform_now"
```
