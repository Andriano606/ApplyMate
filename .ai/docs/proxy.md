# Proxy Validation

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

## Two-phase validation

Phase 1 (fast, eliminates ~95% of candidates):
- TCP CONNECT/SOCKS handshake to `www.google.com:443` — confirms proxy is alive

Phase 2 (real-content check):
- Open tunnel to actual source URL (e.g. `dou.ua:443`, `djinni.co:443`)
- Wrap in TLS via `OpenSSL::SSL::SSLSocket` (fiber-safe in Ruby 3 — see `async.md`)
- Send `GET /`, check 2xx/3xx response

Load source URIs once in `perform` before the `Async` block and pass into `validate` — never query `Source` inside a fiber:

```ruby
source_uris = Source.all.filter_map { |s| URI.parse(s.base_url) rescue nil }
valid = validate(candidates, source_uris)
```

## VALIDATION_CONCURRENCY tuning

This job is pure I/O-bound. CPU core count is irrelevant. The main constraints:

- **File descriptors** — check `ulimit -n` (each fiber holds 1–2 FDs during a probe)
- **Network throughput** — the real ceiling; stop increasing concurrency when `wall_clock` stops improving
- With `VALIDATION_TIMEOUT=3`, throughput ceiling ≈ `CONCURRENCY / 3` probes/sec

Tune by running the job with different env values and comparing `wall_clock` in the debug log:

```bash
FETCH_PROXIES_VALIDATION_CONCURRENCY=2000 bin/rails runner "Proxy::Job::FetchProxies.perform_now"
```
