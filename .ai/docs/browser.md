# Browser layer: browserd and Camoufox

How the apply engine gets a real browser: the `browserd` container hands out short-lived Camoufox (Firefox) browsers
("leases") over the Playwright protocol. Read before touching `docker/browserd/`, the browser Session/Driver/NetTracker/Locate,
the probes, or `ApplyMate::Net::Operation::ResolvePublicAddress` / `GuardedFetch` (PublicAddressGuard).

Code: `docker/browserd/` (`server.mjs` HTTP API + reaper, `leases.mjs` slot bookkeeping, `lease_proxy.mjs` the per-lease
ws proxy, `camoufox.mjs` the one launch options builder, `entrypoint.sh` firewall + proxy + privilege drop, `Dockerfile`, `smokescreen.yaml.tmpl`).

## browserd: image & versions

| Piece | Pinned at | Where |
|---|---|---|
| Camoufox browser | `156.0.1-beta.36` (`lin.x86_64` / `lin.arm64` zip, sha256-verified) | `Dockerfile` ARGs `CAMOUFOX_VERSION`, `CAMOUFOX_RELEASE`, `CAMOUFOX_SHA256_AMD64/ARM64` |
| `camoufox-js` | `0.10.2` + validator patch (`scripts/patch-camoufox.mjs`, npm `postinstall`) | `package.json` / `package-lock.json` |
| `playwright-core` | `1.63.0` | `package.json` / `package-lock.json` |
| uBlock Origin (camoufox-js default addon) | `1.75.0` xpi, sha256-verified | `Dockerfile` ARGs `UBO_URL`, `UBO_SHA256` |
| smokescreen | commit `d533c7aa3eb3ffd2a3fe275dc3bb01dcd2dfa4ea`, built with `golang:1.26-bookworm` | `Dockerfile` ARG `SMOKESCREEN_COMMIT` |
| Node | `node:22-trixie-slim` | `Dockerfile` |

**Image tag (single source):** `andriano606/apply_mate_browserd:156.0.1-beta.36-pw1.63.0-r2` (the triple plus the
browserd revision, Dockerfile `ARG BROWSERD_REVISION`), used by `docker-compose.yml`, CI and Kamal. Bump the
Dockerfile ARGs, `package.json` + lockfile and the tag together; ANY change under `docker/browserd/` (server.mjs,
leases.mjs, entrypoint...) bumps `BROWSERD_REVISION` (see "Image publishing").

**Why this triple is outside declared support.** It is parity with the Stealth Render Studio "Cloudflare" config
that passes Cloudflare/Ashby in practice. `camoufox-js` 0.12.x caps the browser below beta.32 and skips
pre-releases; the official `@camoufox/camoufox` launcher and Python `camoufox` declare `playwright-core < 1.63`. Do
not go below beta.36: Camoufox #825 (`fill()` not firing `change`/`beforeinput`, ignoring `maxlength`) is fixed only
there. camoufox-js 0.10.2 throws `UnknownProperty` on fingerprint keys the 156 build dropped; the postinstall patch
turns that throw into `continue` and fails the install when neither the pattern nor its marker is found.

`playwright-core` rejects a mismatched client only when the client sends a `Playwright/x.y` User-Agent, and the Ruby
gem does not send one. So `/health` and `POST /leases` report `playwright_core`, and the Ruby side must compare it with
`Playwright::COMPATIBLE_PLAYWRIGHT_VERSION` and fail loudly on mismatch.

**Install layout.** camoufox-js resolves the browser from `~/.cache/camoufox` (`/home/browserd/.cache/camoufox`) and
needs `version.json` (`{"version":"156.0.1","release":"beta.36"}`); without it, it tries to download the browser at
launch. The install dir is root-owned and read-only for `browserd`. uBlock Origin is pre-extracted into
`addons/UBO`, so camoufox-js never downloads it at runtime (node has no egress).

**Build fails non-zero** when `TARGETARCH` is not `amd64`/`arm64`, a sha256 does not match, `camoufox-bin` is
missing, `camoufox-bin --version` does not report `CAMOUFOX_VERSION`, the validator patch does not apply,
`npm test` (`test/leases.test.mjs`, `test/lease_proxy.test.mjs`) fails, `smokescreen --help` fails, or `scripts/smoke.mjs` rejects the launch options
(executable path, proxy, WebRTC pref, `CAMOU_CONFIG` present, no `BROWSERD_TOKEN` in the browser env, addon present).
The image is about 3 GB (most of it Camoufox font bundles).

npm audit flags `adm-zip` (a camoufox-js dependency). It is used only by camoufox-js's fetch/addon-download paths,
which never run in this image.

## Environment variables

Read in `docker/browserd/server.mjs` (header) and `docker/browserd/entrypoint.sh` (header). Invalid values exit 1.

| Variable | Default | Meaning |
|---|---|---|
| `BROWSERD_TOKEN` | **required** (≥ 16 chars) | Bearer token for every route except `GET /health` |
| `MAX_BROWSERS` | **required**, `1..3` | Hard cap on concurrent browsers (= the 3 published ws ports). Staging = `APPLY_SLOTS` |
| `PORT` | `9300` | Control API port |
| `LEASE_TTL_S` | `1800` (60..3600) | MAXIMUM lifetime of one lease. Each `POST /leases` asks for its own `ttl_s` (the apply scope deadline + 60 s: about 9 min with an API AI, about 21 min with GeminiScraping), clamped to `[MIN_TTL_S = 60, LEASE_TTL_S]`; a lease without `ttl_s` lives `LEASE_TTL_S`. Must stay ≥ the longest scope (`Context#scope_deadline`, 20 min) + 60 s, or a slow-AI scope's deadline is cut to the lease (apply_engine.md "Latency-aware budgets") |
| `HEADLESS` | `true` | `true` headless; `virtual` = headful under Xvfb `:99` started by the entrypoint; `false` = headful on `$DISPLAY` |
| `BROWSERD_OS` | `windows` | Fingerprint OS (`windows`/`macos`/`linux`) |
| `BROWSERD_LOCALE` | `uk-UA` | Browser locale |
| `BROWSERD_ADVERTISE_HOST` | `os.hostname()` | Host written into `ws_endpoint` (dev: `localhost`, staging: the network alias) |
| `WS_PORT_BASE` | `9301` | Slot `n` serves its ws on `WS_PORT_BASE+n`; its Playwright upstream on `127.0.0.1:WS_PORT_BASE+10+n` |
| `PROXY_URL` | `http://127.0.0.1:4750` | Egress proxy every browser uses (smokescreen) |
| `EGRESS_ALLOW_RANGES` | empty | **Test only** (`browserd-test`, CI). Comma-separated entries smokescreen may reach although private: a CIDR, or a hostname resolved once at start (`getent ahosts`) into one `/32`/`/128` per address (unresolvable → exit 1). Both set `host.docker.internal` (the fixture_site host). Never set on the dev `browserd` or staging |
| `TZ` | `Europe/Kyiv` (image `ENV`) | Browser timezone (geoip is off) |

## Lease API

All routes except `GET /health` require `Authorization: Bearer $BROWSERD_TOKEN` (constant-time compare; `401`
otherwise, also for unknown routes). The header is not CORS-"simple", so page JS cannot forge calls.

| Request | Responses |
|---|---|
| `POST /leases` `{"owner": "<host>:<app dir>:<env>:<pid>:<apply hashid>", "humanize": false, "identity": null, "ttl_s": <int, optional>}` (JSON ≤ 16 KB; `owner` required, 1..200 chars; `identity` optional string; `ttl_s` an integer ≥ 1, clamped to `[MIN_TTL_S = 60, LEASE_TTL_S]` (`leases.mjs`), absent = `LEASE_TTL_S`; Ruby's `AcquireLease` always sends it, see `Session.open`) | `201` `{id, ws_endpoint: "ws://<ADVERTISE_HOST>:<9301+slot>/<64 hex>", expires_at, playwright_version, browser_version, identity}` (`expires_at` reflects the granted, clamped TTL); `503` + `Retry-After: 5` + `{error: "pool_busy", leases, max}` when all slots are taken (or `shutting_down`); `500 {error: "launch_failed"}`; `400 invalid_json`, `413 body_too_large`, `422 owner_required / owner_invalid / identity_invalid / humanize_invalid / ttl_invalid` |
| `DELETE /leases/:id` | `204` after the browser is gone (`close()`, `kill()` after 5 s, `SIGKILL` after 5 more); `404` unknown; `409` still launching |
| `DELETE /leases?owner=<prefix>` | `200 {released: n}`: kills every active lease whose owner starts with the prefix (the apply worker calls this with its hostname on start). `400` without `owner` |
| `GET /health` (no auth) | `200`/`503` `{ok, leases, max, playwright_core, camoufox_build, proxy_ok}`. `ok = proxy_ok && !shutting_down`; `proxy_ok` = TCP connect to the egress proxy |
| `GET /health/deep` | `200 {ok: true, ms, browser}` / `503 {ok: false, ...}`: launches a browser, opens `about:blank`, closes; capped at 20 s. Takes a lease slot (so `MAX_BROWSERS` caps it too; `503 pool_busy` when full); one check at a time |

Each lease is one fresh Camoufox process (`camoufox-js` `launchServer`, fresh random fingerprint per launch) with
`headless`, `os: BROWSERD_OS`, `geoip: false`, `locale`, `proxy: PROXY_URL`, `humanize: humanize ? 0.6 : false`,
`firefox_user_prefs` from `camoufox.mjs` `FIREFOX_USER_PREFS`, an explicit minimal browser env (`PATH HOME TZ LANG
[DISPLAY]`, never `BROWSERD_TOKEN`), Playwright server on `127.0.0.1:<upstream port>` with a random 32-byte hex
`ws_path`. browserd puts a per-lease TCP reverse proxy (`lease_proxy.mjs`) on `0.0.0.0:<WS_PORT_BASE+slot>` in front of
it; it accepts only the exact `ws_path` (`404` otherwise), at most **one** ws client at a time (`409`), only while the
lease is `active` (`410`), and counts connections for the reaper. A rejected upgrade gets its status line and is then
**destroyed** (at most 1 s later, `REJECT_FLUSH_MS`), never left half-open, and every accepted socket (piped or
rejected) is tracked so teardown can destroy it. The `ws_path` is the capability: never log it.

`identity` is accepted, stored and echoed only. There is no per-identity fingerprint cache yet (see Deviations).

Clients connect with `Playwright.connect_to_browser_server(ws_endpoint, browser_type: 'firefox')`; when the ws
connection drops, Playwright closes every context that connection created, and the reaper kills the browser.

## Reaper rules

`server.mjs` runs `reap()` every 15 s (`REAPER_INTERVAL_MS`); rules live in `leases.mjs` (`LeaseTable#reapable`,
unit-tested in `test/leases.test.mjs`). Only `active` leases are reaped; a `launching` lease belongs to its `POST`,
which tears it down itself on any failure (including the client going away mid-launch).

| Rule | Threshold |
|---|---|
| TTL | `now ≥ expires_at` (the lease's own TTL, i.e. its clamped `ttl_s` or `LEASE_TTL_S`, counted from readiness) |
| Never connected | no ws client within 60 s of readiness (`NEVER_CONNECTED_GRACE_MS`), so reaped within ~75 s |
| Disconnected | connection count back to 0 for ≥ 30 s (`DISCONNECT_GRACE_MS`) |
| Process exited | Firefox exit event (also released immediately from the `exit` handler) |

A slot is freed only after the lease proxy and the browser are gone, and teardown is bounded: `closeLeaseProxy` ≤ 5 s
(`CLOSE_GRACE_MS`; on timeout `lease_proxy_close_timeout` is logged and teardown goes on, the listener is already
closed), then browser `close()` 5 s + `kill()` 5 s + `SIGKILL`. So `DELETE /leases/:id` answers within ~15 s, under
the Ruby client's 20 s timeout, and a `releasing` lease always reaches `release()` (the reaper never looks at
`releasing` leases, so an unbounded step there would pin the slot until a restart). A new lease never binds the port
of a dying one. The reaper tick also probes the egress proxy: 4 consecutive failures
(from the reaper or `/health`) → kill all leases and exit 1, and the container restart policy brings back firewall,
proxy and node together. `SIGTERM`/`SIGINT` → stop accepting leases, kill all (8 s cap), exit 0.

## Network isolation

Goal: third-party page JS never reaches anything but the public internet.

- **uids.** `browserd` (1001) runs node and every Firefox it launches. `egress` (1002) runs smokescreen, the only
  process with outbound network. The entrypoint runs as root with `CAP_NET_ADMIN`, installs the firewall, then
  `setpriv --reuid=browserd --regid=browserd --init-groups --inh-caps=-all --bounding-set=-all --no-new-privs`.
- **iptables** (own chain `BROWSERD_EGRESS`, jumped from `OUTPUT`; any failing rule aborts the start):
  1. `-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT` (replies on connections Rails opened to browserd)
  2. `-m owner --uid-owner browserd -o lo -d 127.0.0.1 -p tcp --dport 4750 -j ACCEPT` (smokescreen)
  3. `-m owner --uid-owner browserd -o lo -d 127.0.0.1 -p tcp --dport 9311:93xx -j ACCEPT` (node → its leases'
     Playwright upstreams; range = `WS_PORT_BASE+10 .. +MAX_BROWSERS-1`)
  4. `-m owner --uid-owner browserd -j REJECT` (everything else, including DNS and the control/ws ports)

  `ip6tables` gets rules 1 and 4 whenever any interface has IPv6 enabled. After installing, the entrypoint checks that
  `browserd` can NOT open `1.1.1.1:80` and CAN open `127.0.0.1:4750`, and exits 1 otherwise.
- **smokescreen** listens on `127.0.0.1:4750`, resolves DNS itself and denies loopback, link-local, RFC1918/ULA,
  CGNAT (`100.64.0.0/10`, also explicit in `deny_ranges`), `0.0.0.0/8` and the container's own addresses. No ACL
  file (`allow_missing_role: true`): any public address is allowed. `EGRESS_ALLOW_RANGES` renders into
  `allow_ranges` (default `[]`); it exists only so the test browserd (`browserd-test`, CI) can load the host-served
  fixture_site, and there it opens exactly the docker host's `/32`. The dev `browserd` that `bin/dev` applies use
  has no allow list: real job pages cannot reach the developer's LAN or the docker host's services.
  A denied destination gets **`407`** from smokescreen (not `403`); page JS sees a failed or opaque response.
  smokescreen logs one `CANONICAL-PROXY-DECISION` JSON line per connection (host:port only, never paths) to the
  container log. Every fresh profile also sends Firefox background traffic through it (uBlock filter lists,
  `aus5.mozilla.org`, OpenH264/Widevine plugin downloads); that is egress volume per lease, not a leak.
- **Firefox prefs.** `media.peerconnection.enabled=false` (WebRTC off: no local IP leak, no UDP around the proxy);
  `network.proxy.allow_hijacking_localhost=true` (localhost also goes through smokescreen, which denies it).
- **Ports.** Control `9300`, ws `9301-9303` (one per slot). Upstreams `9311-9313` bind `127.0.0.1` only.
- **node** needs no outbound: geoip is off, camoufox-js finds browser and addon pre-installed, no telemetry.

## Ruby lease client

Code: `app/concepts/apply_mate/client/browser/` (`browserd.rb`, `lease.rb`, the error classes) and
`app/concepts/apply_mate/client/browser/operation/`. All three operations are internal (`skip_authorize`).

**`ApplyMate::Client::Browser::Browserd`** is the single reader of the connection settings:

| Method | Value |
|---|---|
| `.url` | `ENV.fetch('BROWSERD_URL')` (dev `http://localhost:9300`) |
| `.token` | `ENV.fetch('BROWSERD_TOKEN')` (must equal the container's token) |
| `.owner_prefix` | `"#{Socket.gethostname}:#{Rails.root.basename}:#{Rails.env}:"`. Owner tags are `"<prefix><pid>:<apply hashid>"`. App dir + env separate processes that share a hostname and a browserd (dev: every Conductor workspace, `bin/dev` vs a spec run); in a container they are constant (`rails`, the env). The trailing colon stops host `worker` from matching `worker2` |
| `.http` | `Faraday.new(url:, headers: { Authorization: "Bearer …", Content-Type: application/json }, request: { open_timeout: 5, timeout: 20 })` |

Both variables are read at call time, never at boot: web and the general worker run without them, and the first
lease call raises `KeyError` ("BROWSERD_URL is not set …"). There is no fallback driver.

**`Operation::AcquireLease.call(owner:, humanize: false, identity: nil)`**, model =
`ApplyMate::Client::Browser::Lease` (`Data.define(:id, :ws_endpoint, :expires_at, :playwright_version,
:browser_version)`, `.from_json(hash)`; `inspect`/`to_s` omit `ws_endpoint`, the capability).

| browserd answer | Result |
|---|---|
| `201` | the lease |
| `503` | sleep `Retry-After` (default 5 s, capped at 10 s; `Clock.sleep_ms`), POST again; after `BUSY_ATTEMPTS = 3` POSTs (2 sleeps, ≤ 20 s) raise `PoolBusy` |
| `401` / other `4xx` / `5xx` / `Faraday::Error` (refused, timeout) / unreadable `201` body | raise `Crashed` immediately, no retry here |
| `playwright_version != Playwright::COMPATIBLE_PLAYWRIGHT_VERSION` | `ReleaseLease`, then raise `VersionMismatch` |
| `BROWSERD_URL`/`BROWSERD_TOKEN` unset | `KeyError` (configuration, not wrapped) |

Termination: the busy loop is bounded by `BUSY_ATTEMPTS` (no caller-tunable knob); every other outcome raises on the
first answer. The POST uses
`LAUNCH_TIMEOUT_S = 75` instead of the 20 s default, because browserd caps a launch at 60 s plus up to 10 s of
teardown before its `500`; a shorter client timeout would abandon launches the server is about to finish. A `201`
we cannot parse leaves a lease we cannot address; the never-connected reaper rule frees it within ~75 s.

Errors (`app/concepts/apply_mate/client/browser/*.rb`, all `< StandardError`): `PoolBusy` (transient: wait for
capacity), `Crashed` (transient: browserd down, token mismatch, launch failure), `VersionMismatch` (permanent until
the image and the Gemfile pin `playwright-ruby-client 1.63.0` are bumped together). How the Runner maps them is in
`.ai/docs/apply_engine.md` (phase 2 unit 4).

**`Operation::ReleaseLease.call(lease:)`**: `DELETE /leases/:id`. model `true` on `204` or `404` (already reaped),
`false` otherwise. Never raises (it runs in `ensure`): every failure is logged as `browserd.release_failed` and the
reaper frees the slot anyway.

**`Operation::ReleaseOrphanLeases.call(owner_prefix:)`**: `DELETE /leases?owner=<prefix>`. model = released count,
or `nil` (logged `browserd.orphan_sweep_failed`) when browserd is unset, unreachable or answers non-`200`. A blank
prefix raises `ArgumentError` (it would release every lease).

**Boot sweep** (`config/initializers/browserd_leases.rb`): `SolidQueue.on_start` calls `ReleaseOrphanLeases` with
`Browserd.owner_prefix` unless `AssertQueueTopology.role == 'general'`. Supervisor start hooks run before the workers
start, so no lease of the new process exists yet. `on_start` hooks cannot abort boot, and nothing about browserd
should. Kamal gives each new container a fresh hostname (`<host>-<random hex>`), so this sweep frees leases of a
restarted container (same hostname); after a deploy the old container's leases are freed by the disconnect reaper
rule once its process exits (≤ ~45 s). On a dev machine the prefix's app dir + env keep one workspace's `bin/dev`
from sweeping another workspace's leases or its own `:browser` spec run.

## PublicAddressGuard

`ApplyMate::Net::Operation::ResolvePublicAddress.call(url:)` (`app/concepts/apply_mate/net/operation/`) is the one
implementation. Every fetch of a URL that came from a page, an AI or a redirect goes through it before the request.
model = `Resolution` (`Data.define(:url, :host, :port, :ip)`, `ip` = the first IPv4 answer, else the first answer:
the pin forbids curl a family fallback, and Resolv may list AAAA first, which fails on an IPv4-only host).

1. `URI.parse`; the scheme must be `http`/`https` and the host present, else `UnsafeUrlError` reason `:scheme`
   (also for unparsable URLs).
2. A literal IP is used as is (no DNS). A hostname goes through
   `Resolv.new([Resolv::Hosts.new, Resolv::DNS.new` with `timeouts = 3`)`.getaddresses`. No answers → `:unresolvable`
   (this also catches browser-only IP spellings such as `http://2130706433/`).
3. **Every** address must be public, else `:private`. One private answer among public ones is rejected (DNS
   rebinding mix). An answer `IPAddr` cannot parse (e.g. scoped `fe80::1%lo`) counts as private.

`BLOCKED_RANGES`: `0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24
192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4 ::/128 ::1/128 fc00::/7 fe80::/10`. IPv4-mapped IPv6
(`::ffff:0:0/96`) is unwrapped and its IPv4 checked. That rule is `ResolvePublicAddress.public_ip?(ipaddr)`, the
one implementation; `ResolvePublicAddress.literal_private?(host)` applies it **without DNS** (true for `localhost`,
`*.localhost` and literal non-public IPs, bracketed or not, also in the fully-qualified trailing-dot form Firefox keeps
in frame URLs (`localhost.`, `app.localhost.`); false for any hostname) for URLs the guard never saw,
such as frames the browser already loaded (`Apply::Gate::PrivateAddress`).

`ApplyMate::Net::UnsafeUrlError` (`reason` ∈ `:scheme :unresolvable :private`, `url`) names only the host in its
message; the full URL may carry tokens. The Runner maps it to the code `private_address` (`unsupported`), wired in
phase 2 unit 4. The browser itself is covered by smokescreen (see Network isolation); the guard is the Ruby-side check
before navigation.

**HTTP fetches of untrusted URLs: `ApplyMate::Net::Operation::GuardedFetch.call(url:, http:, method: :get, body: nil,
headers: {})`** (`app/concepts/apply_mate/net/operation/guarded_fetch.rb`, internal, `skip_authorize`) is the one
implementation (DetectPlatform's redirect walk, `fetch_schema`). model = `ApplyMate::Client::Response`.

1. `ResolvePublicAddress` (raises `UnsafeUrlError` before any request).
2. ONE request: `http.get(url, headers:, follow_redirects: false, resolve:)` or `http.post(url, body:, headers:,
   resolve:)`. A 3xx is returned as is; a caller that walks redirects sends every `Location` through `GuardedFetch`
   again, so every hop is checked and pinned.
3. `http` must be an `ApplyMate::Client::ImpersonateHttp` (else `ArgumentError`): `AsyncHttp#get` takes `**` and would
   silently drop `resolve:`.

`ImpersonateHttp#get`/`#post` take `resolve:` (a `Resolution` or `nil`). With it, curl gets `--resolve
host:port:ip` (`port` = the URL's, default 443/80; IPv6 in brackets) and `--noproxy '*'` (no env proxy), and never
`-L`. `ArgumentError` (before curl runs) for `resolve:` + `follow_redirects: true`, + a client `proxy:` (the proxy would
resolve the host itself), a `Resolution` without `ip`, or one for another host. In `:browser` specs
`FixtureSite.resolution` returns `ip: '127.0.0.1'` (the fixture server runs in the spec process), so a pinned
Ruby-side fetch of `FixtureSite.url(...)` works.

## Session API

Code: `app/concepts/apply_mate/client/browser/session.rb` (facade), `driver/playwright.rb` (the only driver),
`net_tracker.rb`, `target.rb`, `nav_result.rb`, `snapshot.rb`, `obstructed.rb`, `clock.rb`, `probe/*.js`, and the
algorithms as internal operations in `operation/` (`Goto`, `WaitPastCloudflare`, `WaitForContentSettle`, `WaitQuiet`,
`Locate`, `WaitReady`, `SnapshotAll`, `ReadListbox`, `WaitForListbox`, `WaitUntil`).

```ruby
ApplyMate::Client::Browser::Session.open(deadline: ctx.scope_deadline, owner: Session.owner_for(apply)) do |session|
  nav = session.goto(url)                                   # NavResult
  session.click(Target.css('button', has_text: 'Apply'))
  session.settle(:click)                                    # actions never settle implicitly
end
```

**`Session.open(deadline:, owner:, humanize: false, identity: nil)`**:
`AcquireLease` → `Driver::Playwright.new(lease:, deadline:).start` → `yield session` → `ensure driver&.close`. `close`
disposes the tracker, stops the Playwright connection (errors logged as `browser.driver_stop_failed`) and always calls
`ReleaseLease`, so the lease is released when the block raises and when `start` fails after the lease was granted.
`deadline` is a `Time` (the Runner's scope deadline, `Context#scope_deadline`: `SCOPE_DEADLINE` 8 min plus the slow-AI
allowance, 20 min with GeminiScraping). The lease asks for `ttl_s = ceil(deadline - now) + LEASE_MARGIN_S (60)`; the
driver's deadline is `min(deadline, lease.expires_at - 60 s)`, so a browserd that grants less ends the scope cleanly. `Session.owner_for(apply)` = `"<Browserd.owner_prefix><pid>:<apply hashid>"`.

`Driver#start`: `Playwright.connect_to_browser_server(ws_endpoint, browser_type: 'firefox')` (bounded by
`CONNECT_TIMEOUT_S = 30`), `browser.new_context` **without options**, `new_page`, `NetTracker.new(page)`.

| Method | Visibility | Does |
|---|---|---|
| `goto(url)` | — | `Operation::Goto` → `NavResult(status, final_url, challenge_passed, was_challenge)` |
| `click(target)` | `:required` | `locator.click` (trusted input, Playwright actionability waits) |
| `trial_click(target)` | `:required` | `locator.click(trial: true)`: the same actionability checks (an obstruction raises `Obstructed`), no click; `Stage::Submit` runs it inside `GuardAction` before the claim |
| `fill(target, text)` | `:required` | `locator.fill` |
| `type(target, text, delay_ms: rand(40..90))` | `:required` | `locator.press_sequentially(delay:)`; timeout `ACTION_TIMEOUT_MS + text.length × delay_ms` |
| `press(target, key)` | `:required` | `locator.press` |
| `select(target, value: nil, label: nil)` | `:required` | `locator.select_option` |
| `set_checked(target, value)` | `:attached` | `locator.set_checked` |
| `upload(target, path, via_chooser: false)` | `:attached` (`:required` with `via_chooser`) | `set_input_files(path)`, or `expect_file_chooser { target.click }.set_files(path)`; files stream over the protocol |
| `scroll_into_view(target)` | `:attached` | `locator.scroll_into_view_if_needed` |
| `probe(name, target, arg = nil)` | `:attached` | `locator.evaluate(PROBES[name], arg)`. `probe(:anchor, root)` → `{ 'selector', 'container' }`: `selector` re-addresses the element by the first of `#id` (stable, CSS-safe), `tag[data-*="v"]` / `tag[name="v"]`, `tag[role=r][aria-label="v"]` / `tag[role=r]`, `form` (the only one) that is unique in its document, else the nearest such ancestor plus at most 6 `nth-of-type` steps, else `nil` (nothing stable; never inside a shadow tree); `container` is the nearest `dialog` / `[role=dialog]` / `[role=alertdialog]` / `[aria-modal=true]` / `.modal` ancestor (same rule, else its absolute path), `nil` when none |
| `present?(target, visibility:)` | given | `Locate`, `TargetNotFound` → `false` |
| `ready?(root_target, timeout:, min_fields: 1, keys: nil, attr: nil, ratio: 0.8, key_prefix: nil)` | `:attached` | `Operation::WaitReady` (`timeout` in seconds) → Boolean; keys mode when `keys:` given (see Probes `readiness`); `key_prefix` = the platform's per-render prefix (`Readiness#key_prefix`) |
| `snapshot_all(markers: [], regions: [])` | — | `Operation::SnapshotAll` → `Snapshot` (below); `markers` are counted by `detect.js`, `regions` (CSS selectors, e.g. the platform's form root and excluded autofill pane) come back per element as `'regions'` (the ones the element or its field root sits inside) |
| `dom_mark(target)` | — | `Operation::ReadListbox` in the target's frame and the top document → `{ frame_path:, option_count:, containers: { 'frame' / 'top' => { container key => visible option count } } }` |
| `wait_for_listbox(since:, timeout:)` | — | `Operation::WaitForListbox`: polls `ReadListbox` every 100 ms → `[WaitForListbox::Option(label, target)]` of options new since the mark (disabled ones dropped), or `[]` at `timeout` seconds (clamped to the deadline); never raises because nothing opened |
| `wait_until(timeout:) { … }` | — | `Operation::WaitUntil`: the block every 250 ms → its first truthy value, or `false` at `timeout` seconds (clamped). `TargetNotFound` / `Playwright::Error` in the block count as "not yet"; anything else propagates |
| `html(frame_path: [])` | — | `page.content`; with a frame path the `outer_html` probe on that frame's `:root` |
| `frames` | — | `[{ 'url', 'name' }]` of every frame |
| `screenshot(full_page: false, mask_fillable: false)` | — | PNG bytes; `mask_fillable` paints over `Driver::Playwright::MASK_SELECTOR` (`input:visible, textarea, select, [contenteditable], [role=combobox], [role=textbox]`) in the main frame and every child frame (first `MAX_FRAMES`) |
| `cookies` | — | `"name=value; …"` of the context |
| `current_url` | — | `page.url` |
| `pages` | — | `[{ 'url' }]` of every page (tab) of the context, oldest first (`context.pages`); a tab a click opened (`target=_blank`, `window.open`) is appended. Browsers report a new tab 0.5–1.5 s after the click (measured on Camoufox: ~1.5 s for the first, ~0.5 s later), i.e. usually after `settle(:click)` returned: poll with `wait_until` |
| `switch_to(index)` | — | `Driver#switch_to`: `context.pages.fetch(index)` (`IndexError` for an unknown index) → `bring_to_front` → its `domcontentloaded` (at most `ACTION_TIMEOUT_MS`, a slow page is switched to anyway) → the session's page. Every other method (frames, content, snapshots, screenshots, `current_url`, actions) follows it. **The NetTracker is per page**: the old one is disposed and a new one bound to the new page, with the `network_watch` patterns carried over; marks taken before the switch are void for `network_since` / `network_in_flight` (requests of the old page are gone). The caller settles the new page (`settle_content`) |
| `settle(kind)` | — | `Operation::WaitQuiet` with profile `kind` → `{ quiet:, ms: }` |
| `settle_content` | — | `Operation::WaitForContentSettle` → Boolean |
| `network_mark` / `network_since(mark, bodies: false)` | — | `NetTracker#mark` / `#since` |
| `network_in_flight(mark)` | — | `NetTracker#in_flight_since(mark)`: non-GET, non-ignored requests started at or after `mark` that have not finished or failed yet, however old |
| `network_watch(pattern)` | — | `NetTracker#watch(pattern)`: capture response bodies of matching requests |

Callers: the apply engine only (`.ai/docs/apply_engine.md`), each through a Runner session scope (`:survey` with
`humanize: false`, `:submit` with `humanize: true`); `Apply::Operation::SmokeSurvey` opens one non-humanized lease
the same way:

| Engine caller | Session methods |
| ------------- | --------------- |
| `Engine::CollectRenderedEvidence`, `RunGates` / gates (`CookieConsent` clicks) | `snapshot_all`, `current_url`, `click` |
| `Engine::ReachForm`, `Engine::Observe`, `Engine::WaitReady` | `goto`, `current_url`, `snapshot_all`, `frames`, `wait_until`, `ready?` (ReachForm's landing: `ready?(body, timeout: 0)` ends the identify wait) |
| `Engine::Navigate` (the AI Navigator), `Engine::ExecuteAction`, `Engine::AdoptNewTab` | `snapshot_all(markers:, regions:)`, `current_url`, `pages`, `probe(:opens_tab)`, `probe(:anchor)` / `probe(:readiness)` (the claimed root), `goto` (an `navigate` action), `wait_until`; clicks / presses / scrolls go through the recipe ops below |
| `Engine::RecoverField` | `snapshot_all(regions:)`; its click / press through the recipe ops |
| `Engine::AwaitInput` (`Gate::EmailCode`) | `snapshot_all(markers:)`, `click`, `press`, `settle(:submit)`; the code is typed by the `Text` widget |
| `Recipe::Interpret`, recipe ops (`apply/recipe/op/*`: `Goto`/`Unwrap`, `Click`, `Press`, `Scroll`, `SwitchTab`, `WaitFor`) | `pages`, `probe(:opens_tab)`, `goto`, `click`, `press`, `scroll_into_view`, `settle(:click / :key)`, `wait_until`, `switch_to`, `settle_content`, `ready?`, `current_url` |
| `Engine::FormElements`, `Engine::BuildFieldInventory` | `snapshot_all(markers:, regions:)`, `probe(:read_value)` (default values) |
| `Engine::GuardAction`, `Engine::SetFieldValue` | `snapshot_all`, `settle(kind)` |
| Widgets (`apply/widget/*`) | `fill`, `type`, `press`, `click`, `select`, `set_checked`, `upload`, `present?`, `dom_mark`, `wait_for_listbox`, `probe(:read_value)`, `probe(:snapshot)` |
| `Stage::FillFields` (wizard Next) | `click`, `settle(:click)`, `snapshot_all` |
| `Stage::Submit` | `snapshot_all`, `trial_click`, `network_watch`, `network_mark`, `click`, `settle(:submit)` |
| `Engine::VerifySubmit` / `CollectSubmitEvidence`, `Stage::Verify` | `wait_until`, `html(frame_path:)`, `current_url`, `frames`, `network_since(mark, bodies: true)`, `network_in_flight(mark)`, `probe(:read_value)`, `screenshot(full_page: true, mask_fillable: true)` |
| `Engine::CaptureArtifact` | `screenshot(mask_fillable: true)`, `frames`, `html(frame_path:)` |

Step specs use `FakeSession` (`.ai/docs/rspec.md`), whose method
list and parameters `session_contract_spec.rb` keeps identical to this class (its `pages:` knob and `open_page(url)`
script tabs).

**`Snapshot`** (`ApplyMate::Client::Browser::Snapshot = Data.define(:frames, :elements, :evidence, :digest)`),
built by `Operation::SnapshotAll`: one `Driver#evaluate_all_frames` call runs `snapshot.js` and `detect.js` on each
frame's `document.documentElement` (first `Driver::Playwright::MAX_FRAMES = 20` frames, main first).

| Part | Shape |
|---|---|
| `frames` | `[{ 'ref' => 'f<i>', 'index', 'url', 'title', 'parent' => nil \| 'f<j>', 'frame_path', 'outline', 'alerts', 'captcha', 'password_fields', 'truncated', 'readable' }]`; `readable: false` when the frame could not be evaluated (no elements) |
| `elements` | every probe element plus `'ref' => 'f<i>:e<j>'`, `'frame' => 'f<i>'`, `'fingerprint' => "role\|name\|f<i>"` (role or tag, name downcased; then `\|<scope>` when the probe reports a `scope`: `dialog` / `form`, `#id` added for a stable container id, else `@n` for the n-th container of that kind, so a modal's button never inherits a page launcher's identity or FORBIDDEN entry; the n-th repeat of one such key in a frame gets `#<n>`, the first stays plain) and `'target'` (a `Target`) |
| `evidence` | `{ frame_urls:, script_srcs:, iframe_srcs:, dom_markers: { marker => count summed over frames } }` |
| `digest` | SHA1 of the fingerprints joined in order |

Frame path of a child frame: its parent's path plus `{ 'selector' => 'iframe#<id>' }` when the `<iframe>` element has
a CSS-safe id (`Driver#evaluate_all_frames` reads it via `frame.frame_element` from the parent side, so it works across
origins), else `{ 'url_contains' => <frame url> }`. A child whose parent is not among the evaluated frames gets one
flat `url_contains` hop (never the main frame's path). An element's `Target` = that frame path + the probe's `strategies`
+ `readonly`; `root` (the probe's `root_strategies`) is set only for radios, checkboxes, file inputs and any element
that is `visible` through its label/root/dropzone but not `self_visible` (Locate then judges `:required` on the root).

**`Operation::Goto`** (port of `gotoSmart`): `ResolvePublicAddress` (raises `UnsafeUrlError` before any navigation)
→ `driver.navigate(url)` (`waitUntil: 'domcontentloaded'`, `NAVIGATE_TIMEOUT_MS = 30_000`) →
`WaitPastCloudflare(max_ms: 40_000)` → settle: network idle OR a form already rendered, whichever comes first, at most
`NETWORK_IDLE_MS = 8_000` (a timeout there is fine): `wait_for_network_idle` in `IDLE_SLICE_MS = 1_000` slices, each
preceded by one `Operation::WaitReady(body, min_fields: RENDERED_FORM_FIELDS = 3, timeout_ms: 0)` probe, so a
server-rendered page whose form is on screen is not held the full 8 s by beacons that never go idle. A navigation error
(timeout, `NS_ERROR_*`, smokescreen `407` on a redirect to a private host) propagates as `Playwright::Error`.

**`Operation::WaitPastCloudflare`** (port of `waitPastCloudflare`), model `[passed, was_challenge]`. Predicate:
`ApplyMate::Client::Response.cloudflare_interstitial?` on `title` or `content` (the `CLOUDFLARE_MARKERS` minus
`challenge-platform`, see Deviations). While challenged: `mouse_move(rand(80..1000), rand(80..650), steps: 6..16)`,
`mouse_wheel(0, rand(-60..160))` every 3rd poll, sleep 900..1400 ms. Never challenged → `[true, false]` after 2 polls
(300 ms apart). Challenged then cleared → `[true, true]` once `body.innerText` (first 600 chars, whitespace removed)
exceeds 80 chars or 2 s have passed since the start. Budget `min(max_ms, remaining)` → `[false, was_challenge]`. A
read that fails mid-navigation counts as empty.

**`Operation::WaitForContentSettle(max_ms: 9_000)`**: sum of `document.body.innerText.length` over `driver.frames`
(a frame that cannot be evaluated counts 0) every 500 ms; settled when non-zero and unchanged on 2 consecutive polls.

## Target & Locate rules

`ApplyMate::Client::Browser::Target = Data.define(:frame_path, :strategies, :root, :readonly)`; `from_h` (string or
symbol keys) / `to_h` (adds `'type' => 'browser'`) round-trip; `Target.css(selector, has_text: nil, nth: nil,
frame_path: [])` builds a one-strategy target.

| Part | Shape |
|---|---|
| `frame_path` hop | `{ 'selector' => 'iframe#x' }` → `frame_locator` chain; `{ 'url_contains' => '…' }` / `{ 'name' => '…' }` → first of `page.frames` (flat: searches the whole page) |
| strategy | `{ 'css', 'has_text'?, 'nth'? }` → `locator(css).filter(hasText:).nth(n)`; `{ 'role', 'name'? }` → `get_by_role`; `{ 'label' }` → `get_by_label`; `{ 'attr' => { name => value } }` → `[name="value"]…` (unsafe attribute names skip the strategy) |
| `root` | strategies of the field root (styled controls) |

`Operation::Locate.call(driver:, target:, visibility:)`, model = Playwright locator:
1. Resolve `frame_path` hop by hop from `page.main_frame`; an unmatched `url_contains`/`name` hop → `TargetNotFound`.
2. Strategies in order; a strategy is accepted only when it matches exactly **one element in the DOM**, hidden or
   not (`count(locator) == 1`, never counted after a visibility filter). 0 or >1 matches, or an invalid selector, →
   next strategy. One uniqueness rule for both modes, so a target resolves to the **same** element in `:required`
   and `:attached` (a responsive page's hidden mobile copy next to the visible input makes that strategy a miss in
   both, instead of `fill` hitting the visible one and `read_value` another).
3. `:required` additionally needs the one element to be visible (`count(locator.filter(visible: true)) == 1`); when
   `target.root` is set, the root must match exactly one element and that one be visible, and the element only be
   attached (`TargetNotFound` "field root is not visible" otherwise). `:attached`: in the DOM is enough. Playwright
   counts `opacity: 0` and 1×1 clipped elements as visible; `display: none` / `visibility: hidden` / empty boxes as
   hidden.
4. None accepted → `TargetNotFound` (`#target`; `#ambiguous?` = some strategy matched several elements). Counting
   does not wait: wait first (`ready?`, `settle`).

`Operation::WaitReady.call(driver:, target:, timeout_ms:, min_fields: 1, keys: nil, attr: nil, ratio: 0.8, key_prefix: nil)`: every
250 ms, `Locate(:attached)` the root and run the `readiness` probe (`{ min, keys, attr, ratio, keyPrefix }`; `keys` without `attr`
→ `ArgumentError`); `true` once it reports `ready`, `false` at `min(timeout_ms, remaining)`. An
**ambiguous** root (`TargetNotFound#ambiguous?`, e.g. `form` on a page that also has a search form) returns `false` at
once: the target is too broad and polling would burn the deadline on an answer that cannot change.

## Settle profiles

`Operation::WaitQuiet.call(tracker:, profile:, deadline:)` (port of `waitQuiet`), model `{ quiet:, ms: }`. Returns
once `elapsed ≥ min`, `tracker.pending(ignore_older_ms: 3_000) == 0` and the last network event is `quiet` ms old;
gives up at `max`. Polls every 50 ms. `max` is clamped to the time left before the deadline (none left →
`{ quiet: false }` at once; the next driver primitive raises `DeadlineExceeded`).

| Profile | min (ms) | quiet (ms) | max (ms) |
|---|---|---|---|
| `:click` | 150 | 300 | 2 500 |
| `:key` | 50 | 200 | 1 500 |
| `:file` | 300 | 500 | 8 000 |
| `:submit` | 500 | 1 000 | 15 000 |

## NetTracker

`NetTracker.new(page)` subscribes `page.on('request' | 'requestfinished' | 'requestfailed')` (every frame of the page).
One tracker per page: requests of another tab are not seen, and `Session#switch_to` rebinds it (above).
Events arrive on the gem's reader thread: state lives in `Concurrent::Map` (in flight, keyed by the request object),
`Concurrent::Array` (records) and `Concurrent::AtomicReference` (last event); callbacks never call back into
Playwright (a blocking call from the reader thread deadlocks it) and never raise (that would kill the dispatch loop).

| API | Value |
|---|---|
| `pending(ignore_older_ms: 3_000)` | in-flight requests (any method) younger than `ignore_older_ms`; ignored ones older than `STALE_MS = 60_000` are dropped for good |
| `last_event_at` | monotonic ms of the last request start/finish/failure (`-Infinity` before any) |
| `mark` / `since(mark)` | monotonic ms / records whose request started at or after `mark` |
| `in_flight_since(mark)` | non-GET, non-`IGNORED_HOSTS` requests started at or after `mark` still in flight (no age cut-off: a slow submit POST is never "too old"); `VerifySubmit` refuses `:rejected` while it is > 0 |
| `watched` | the `watch` patterns (`Driver#switch_to` re-registers them on the next page's tracker) |
| `dispose` | unsubscribes (`Driver#close`, `Driver#switch_to` for the page it leaves) |

A record `{ url:, method:, status:, at:, frame_url:, body:, body_error: }` is written when a **non-GET** request finishes (`status`
from `request.existing_response`) or fails (`status: nil`), unless its host matches `IGNORED_HOSTS` (suffix match;
`host/path` entries also match a path prefix): `google-analytics.com googletagmanager.com doubleclick.net recaptcha.net
gstatic.com/recaptcha google.com/recaptcha hcaptcha.com challenges.cloudflare.com sentry.io segment.io hotjar.com
facebook.net datadoghq.com datadoghq.eu browser-intake-datadoghq.com browser-intake-datadoghq.eu
browser-intake-us3-datadoghq.com browser-intake-us5-datadoghq.com browser-intake-ap1-datadoghq.com` (Datadog RUM beacons,
which Ashby sends around the submit, go to `browser-intake-<site>` hosts that are not subdomains of `datadoghq.*`).
At most `MAX_RECORDS = 500`, oldest dropped. Request bodies are never stored (they carry the
applicant's answers).

**Response bodies** (`watch(pattern)`, a `Regexp`; the platform's `success_evidence[:submit_request]` URL, which names
the submit operation itself — Ashby's `submit_url` matches only `?op=ApiSubmit…`, so autosave / upload / analytics
calls never take a read slot): for a **finished** non-GET request whose URL matches a watched pattern, the reader
thread only *posts* the read to a per-tracker `Concurrent::ThreadPoolExecutor` (`max_threads: 1`,
`max_queue: BODY_QUEUE = 8`, `fallback_policy: :abort`; a rejected post records the `DROPPED` handle, never blocks or
raises). The read (`request.response.body`, a Playwright call)
runs on that thread eagerly, while the browser still holds the response, and keeps the first `BODY_CAP = 64.kilobytes`
(UTF-8, scrubbed). `since(mark, bodies: true)` waits on the **caller** thread for those reads, `BODY_WAIT_MS = 5_000` in
total, and returns the strings. When a watched request with a status has no body, `body_error` says why: `dropped`
(queue full / tracker disposed), `unreadable` (the read raised or returned nothing), `timeout` (not done within
`BODY_WAIT_MS`); `VerifySubmit` reports it in `submit_op` (the body is "never read", not "not a success"). With
`bodies: false` (default), and for unwatched requests, `body` and `body_error` are `nil`. Unwatched, GET and failed requests are never read. `dispose` shuts the executor
down (at most one thread per lease, so ≤ `APPLY_SLOTS` threads per worker).

All monotonic time comes from `ApplyMate::Client::Browser::Clock` (`now_ms`, `sleep_ms`, `remaining_ms(deadline)`);
unit specs stub it to drive the wait loops.

## Probes

`app/concepts/apply_mate/client/browser/probe/*.js`: one JS function expression per file, run in the element's
(isolated, on Camoufox) world by `locator.evaluate`. `Driver::Playwright::PROBES` reads them once at class load
(leading `//` comment lines and prettier's trailing `;` stripped); no IO per call. Prettier-checked in CI
(`app/**/*.js`).

All probes are read-only: none marks or mutates the DOM. `snapshot` and `detect` also run per frame through
`Operation::SnapshotAll` (`(arg) => probe(document.documentElement, arg)`); the others through `Session#probe` on a
located element.

| Probe | Signature | Returns |
|---|---|---|
| `snapshot` | `(root, { regions, submitText })` | `{ frame: { url, title }, outline, alerts, captcha, password_fields, truncated, elements }` — the one definition of "interactive element" (design §6.1), see below. The argument is required: every caller passes `Operation::SnapshotAll.probe_arg(markers:, regions:)` (the one source of the `SUBMIT_TEXT` lexicon behind `submit_like`); without `submitText` the probe throws rather than silently stop marking `submit_like` |
| `detect` | `(root, { markers })` | `{ url, name (window.name), title, script_srcs, iframe_srcs, iframes: [{ id, name, src }], dom_markers: { selector => count } }` (an invalid marker counts 0) |
| `listbox` | `(root, { since })` | `{ containers: { key => visible option count }, options: [{ label, value, selected, disabled, listbox_id, strategies }] }` over visible `[role=option]` / `.el-select-dropdown__item` plus ARIA-less leaf items (`[data-value]` that is no form
control, children of a `[class*=results]` / `[class*=suggestions]` container, `li` of a `ul`/`ol` whose class says
suggest / dropdown / autocomplete / options; never inside a `no-result` / `loading` / `empty` status), in document order; container = closest `[role=listbox]`, `.el-select-dropdown`, `ul` (key `#id` or css path). With `since` (an earlier `containers`): only options whose container was absent or whose index in it ≥ the old count |
| `readiness` | `(root, { min, keys, attr, ratio, keyPrefix })` | `{ fields, ready }`. Default: visible fillable controls under root, `ready = fields >= min`. Keys mode (`keys` non-empty): distinct keys found in `attr` of elements under root, any visibility, with `keyPrefix` (a regex source from the platform, e.g. `Apply::Platform::Ashby::INSTANCE_PREFIX_SOURCE`; none when nil) stripped from the start, case-insensitive; `ready = found >= ceil(keys.length × ratio)`. The probe hard-codes no platform rule. (`snapshot.js` / `listbox.js` keep their own UUID-prefix test for a different reason: such ids change per render on any site, so they are never used as locator strategies.) |
| `read_value` | `(el)` | `{ tag, type, value, checked, files, text, displayed, invalid, error_text, pressed, min, max, step, aria_valuenow }`: `displayed` = selected option text / contenteditable text / combobox chip (leaf `[class*=chip]`, `singleValue`, `multiValue`, `single-value`, `multi-value__label` within ≤ 4 ancestors, stopping at the field root) / file names / for a combobox trigger `button` (`aria-haspopup`) its own text / for another `button` or `[role=button]` (a `chooser` dropzone) the text of its field root (`[data-field-path]`, `fieldset`, `[role=group]`), else of its parent, so the chosen file name next to it counts / value; `type` = the `type` attribute (lower-case, null when absent; `Widget::DateInput` picks native vs masked by it); `invalid` = `aria-invalid` or `:invalid`; `error_text` = `[role=alert]`, `[aria-live]` in the field root + the `aria-describedby` targets; `pressed` = `aria-pressed` / `aria-checked` as written; `min` / `max` = the attribute, else `aria-valuemin` / `aria-valuemax`; `step`, `aria_valuenow` as written (`Widget::Range`) |
| `outer_html` | `(el)` | `el.outerHTML` (`Session#html(frame_path:)`) |
| `opens_tab` | `(el)` | `true` when the element sits in an `a[href]` / `area[href]` / `form` whose `target` (else the document's `<base target>`) names another browsing context (`_blank` or a window name, not `_self` / `_parent` / `_top`). `Recipe::Interpret` asks it before a click / press to know whether to wait for a new tab; `window.open` from a script is invisible to it |

**`snapshot.js` elements** (at most 800 per frame, `truncated: true` beyond): native `input` (not hidden; every file
input, even hidden), `textarea`, `select`, `button`, `a[href]`, `summary`, explicit roles `button link tab combobox
listbox option radio radiogroup checkbox switch textbox menuitem dialog`, contenteditable hosts; open shadow roots are
walked. Per element:

- `index tag type role name question` — `role` explicit or implicit (Playwright's mapping); `name` = `aria-labelledby`
  → `aria-label` → content (buttons, links, tabs, options; an EMPTY button / link is named by nothing outside itself,
  only `close` for a `close`/`dismiss` class token) → `label[for]` / parent `label` / `legend` / an adopted label →
  text just before the control (for a checkbox / radio first the text just after it) inside its field root; text
  before a non-checkbox control that holds a link (`a[href]`, a footer "powered by" credit) is not a caption →
  `placeholder` → `title` (unless it only repeats the control's value) → for a file input its `question`. Label text is
  `ownText`: as rendered (CSS-hidden descendants, nested controls and a link / button wrapping a control skipped;
  inline children joined without a separator), required marks (`*`/`✱`, trailing or standalone) stripped. An adopted
  label: a `label[for]` whose control is not rendered (a display:none twin of a Vue phone input or a Froala editor's
  textarea) or does not exist. The walk up has no depth cap (PeopleForce nests its phone input 7 ancestors below the
  label's container) and never crosses `<form>` / `<body>`; the FIRST ancestor holding a second rendered text-entry
  control or any other `label[for]` decides: exactly one label there whose control is unrendered (not a checkbox /
  radio / file) or missing is adopted, anything else adopts nothing. The `{ role, name }` strategy carries the browser's own accessible name (labelledby, aria-label,
  content, own label, placeholder, title), never a heuristic one; `question` = the field root's title
  (`aria-labelledby`, `legend`, or the first label/`[class*=question]`/`[class*=title]`/heading that is not an option
  label).
- One element per clickable thing: a link / button wrapping exactly one other clickable candidate is listed once
  (`<a href><button>` keeps the link, a custom `[role=button]` host around a native `<button>` keeps the native one).
- `captcha_artifact`: the element is a captcha response field (`g-recaptcha-response`, `h-captcha-response`,
  `cf-turnstile-response`).
- state `required` (only for fields, group members and choosers; attribute, `aria-required` on it or its root, `*`/`✱`, a `required` class token such as Ashby's
  `_required_f7cvd_91` or a `[class*=required]` child on the label or question), `invalid` (`aria-invalid` or
  `:user-invalid`), `checked expanded pressed selected disabled readonly`, `filled` (Boolean; values are never
  returned), `aria_hidden`.
- `self_visible` (box, not `visibility:hidden`/`display:none`, no transparent ancestor, not clipped to ≤ 1 px, not
  pushed before the document origin by a negatively offset `absolute` / `fixed` box - the off-canvas honeypot
  `left:-9999px`; a box merely scrolled out of an overflow container still counts) and
  `visible`: = `self_visible`, except file inputs (any label / `[class*=dropzone]` / `[class*=upload]` / nearby
  button seen) and radios, checkboxes, comboboxes (label or field root seen); `in_viewport`.
- `field_root`: closest `[data-field-path]`, else the closest `fieldset` / `[role=radiogroup]` / `[role=group]` that
  holds only this control's group, else (fields only) the highest ancestor (≤ 6 levels, never `form`/`body`) without
  another control group. Exposed as `root_strategies` and `attrs['data-field-path']`.
- `group`: `radio_group` (same `name`, or `role=radio` in a `radiogroup`), `combobox` (`role=combobox` that is not a
  `select`, or a readonly input with `aria-haspopup`, a sibling arrow/indicator, or an `.el-select`/`.v-select`/
  `select__control` ancestor, or a readonly input whose wrapper (≤ 4 ancestors) holds ≥ 2 `[role=option]` /
  `[data-value]` items: an Alpine / jQuery select), `option_group` (a non-submit button in a field root with a question and ≥ 2 such
  buttons); `group_key` on every member, `options: [{ label, value, checked, strategies }]` on the first member.
  Selects carry `options: [{ label, value, selected, disabled }]`; comboboxes `chip` (current chip text).
- flags `password` (`type=password`, `autocomplete` current/new-password), `search_like` (`type=search`, under
  `[role=search]`, `header`, `footer`, a `nav` that is not `[role=tablist]`), `submit_like` (submit type, or a send verb in name/class: `SUBMIT_TEXT` = submit / whole-word send / надіслати / відправити / подати / отправить, never when the text names a code / OTP such as "Resend code" or "Надіслати код", never inside a
  field root, never search-like, only with a fillable control nearby; the text lexicon is `SnapshotAll::SUBMIT_TEXT`), `scope`
  (`dialog` inside `dialog` / `[role=dialog]` / `[role=alertdialog]` / `[aria-modal=true]`, else `form` inside a
  `<form>`, plus `#id` for a stable container id, else `@n`, the container's 1-based position among the same kind
  in its document / shadow root, so two id-less forms are two scopes; null on the page: SnapshotAll's fingerprint,
  ExecuteAction's no-submit guard), `chooser` (a self-visible, non-submit `button` /
  `[role=button]` whose name matches `UPLOAD_LEXICON` = `/upload|attach|resume|\bcv\b|browse|завантаж|прикріп|резюме|загруз/i`
  and whose field root (else its uploader: up to 4 ancestors, stopping at a `<form>` or at an ancestor holding another
  field) holds no `input[type=file]`: a dropzone that creates the file input on click; `BuildFieldInventory` makes it a `file` field with widget `dropzone`), `file_trigger` (a non-chooser, non-submit link / button that wraps an
  `input[type=file]`, or has an `UPLOAD_LEXICON` name and exactly one file input within 3 ancestors: Lever's "ATTACH
  RESUME/CV" anchor, Ashby's "Upload file"; part of that file field: never `submit_like`, left out of the Navigator
  prompt, `ExecuteAction` rejects a click on it as `file_trigger`), `typeahead` (an ARIA-less typeahead: a non-readonly
  `type=text` input without `role=combobox` / `list`, beside a `SUGGEST_CONTAINER` (`[class*=dropdown|suggest|
  autocomplete|typeahead|results]`) within 2 ancestors that hold no other field; → `autocomplete` + `Widget::Typeahead`),
  `href` for links. A custom select trigger (`aria-haspopup=listbox` on a non-input, or a readonly input over a list of
  ≥ 2 `[role=option]` / `[data-value]` items within 4 ancestors) is a `combobox` group; a non-input trigger is named by
  its label, never its content (its current value), and reports `readonly: true` (AriaCombobox clicks, never types).
- `strategies`: `{ attr: { id } }` unless the id is instance-prefixed (`<uuid>_…`) or a React `:r…:` id;
  `{ attr: { name[, value] } }` (radios/checkboxes with value) unless instance-prefixed; `{ role, name }`;
  `{ label }`; always last `{ css: <nth-of-type path> }` (shadow trees joined by a descendant space). `attrs` keeps
  `id name type autocomplete placeholder accept multiple maxlength aria-autocomplete aria-haspopup value data-field-path`
  raw (`aria-autocomplete` / `aria-haspopup` tell a typeahead from a select-like combobox).

Frame-level: `outline` (visible `h1`–`h3`, `tabs A* | B` with `*` = selected, visible dialogs; ≤ 40), `alerts`
(visible `[role=alert]`/`[aria-live=assertive]`, ≤ 10), `captcha` (`recaptcha`, `recaptcha_invisible`,
`recaptcha_challenge`, `hcaptcha`, `hcaptcha_invisible`, `turnstile`, `turnstile_invisible`, `datadome` from iframe
srcs and `.grecaptcha-badge`; an unframed widget - `.h-captcha` / `.g-recaptcha` / `.cf-turnstile[data-sitekey]`, a
captcha response field or an hCaptcha / reCAPTCHA script, framed only on submit - is its `_invisible` kind; a widget counts as visible when its iframe is seen and taller than 30 px; the
`Apply::Gate::VisibleCaptcha` gate stops on the visible kinds only), `password_fields` (visible password elements).

## Deadlines & errors

Every waiting driver primitive clamps its timeout with `clamp_ms(ms) = [ms, remaining_ms].min` and raises
`DeadlineExceeded` when `remaining_ms <= 0` (`navigate`, `wait_for_network_idle`, `click`, `fill`, `type`, `press`,
`select`, `set_checked`, `scroll_into_view`, `upload`, `probe`, `evaluate`, `evaluate_all_frames`, `count`, mouse).
`evaluate_all_frames` and `frame.evaluate` have no Playwright timeout (bounded by the lease TTL like every call
without one); a frame that throws reads as `nil`. Timeouts: actions `ACTION_TIMEOUT_MS =
10_000`, uploads `30_000`, probes `5_000`. Read-only primitives (`title`, `content`, `frames`, `cookies`,
`current_url`, `screenshot` with its own 15 s) are not deadline-checked so failure artifacts can still be captured.
Calls without a Playwright timeout are bounded by the lease TTL: browserd kills the browser, the ws drops, pending
calls fail → `Crashed`.

| Error | Raised by | Runner mapping |
|---|---|---|
| `ApplyMate::Client::Browser::PoolBusy` | `AcquireLease` after `attempts` busy answers | wired in phase 2 unit 4 (`.ai/docs/apply_engine.md`) |
| `ApplyMate::Client::Browser::Crashed` | browserd unreachable/launch failure; any lost connection in the driver (`TargetClosedError`, `DriverCrashedError`, ws transport errors, the gem's `nil.value!` after a drop, connect timeout) | phase 2 unit 4 |
| `ApplyMate::Client::Browser::VersionMismatch` | `AcquireLease` | phase 2 unit 4 |
| `ApplyMate::Client::Browser::DeadlineExceeded` | driver primitives | phase 2 unit 4 |
| `ApplyMate::Client::Browser::TargetNotFound` | `Locate` (all Session actions) | phase 2 unit 4 |
| `ApplyMate::Client::Browser::Obstructed` (`locator`, `reason`) | `click`, `fill`, `type`, `press`, `select`, `set_checked` when Playwright's `TimeoutError` message (with its call log) matches `Driver::Playwright::OBSTRUCTION` (`intercepts pointer events`, `element is not visible/enabled/stable/editable`) | `target_obstructed`, phase 3a unit 4 |
| `ApplyMate::Net::UnsafeUrlError` | `Goto` (before navigating) | `private_address`, phase 2 unit 4 |

Any other `Playwright::Error` (navigation failure, an action timing out on a present element) propagates unchanged.

## Dev / CI / staging wiring

The image tag is the pinned triple `<CAMOUFOX_VERSION>-<CAMOUFOX_RELEASE>-pw<playwright-core>` plus
`-<BROWSERD_REVISION>`, currently `156.0.1-beta.36-pw1.63.0-r2`. It is written in the Dockerfile ARGs, `package.json`/`package-lock.json`,
`docker-compose.yml`, `config/deploy.staging.yml` and (as `playwright-ruby-client (1.63.0)`) `Gemfile.lock`.
`spec/config/browserd_image_tag_spec.rb` fails when any one of them drifts, and when the staging `MAX_BROWSERS` differs
from the apply worker's `APPLY_SLOTS`. Bump all of them in one commit.

### Dev (docker compose + Conductor)

Two services in `docker-compose.yml`, both built from `docker/browserd` (same image; the first build downloads
~1.3 GB), token `${BROWSERD_TOKEN:-dev-browserd-token}`, `pids_limit: 2048`:

| Service | Used by | Ports | `MAX_BROWSERS` | Egress |
|---|---|---|---|---|
| `browserd` | `bin/dev` applies (real third-party pages) | `127.0.0.1:9300-9303` (`PORT` 9300, ws 9301-9303) | `${APPLY_SLOTS:-1}` | public addresses only (no `EGRESS_ALLOW_RANGES`) |
| `browserd-test` | `:browser` specs | `127.0.0.1:9310-9313` (`PORT=9310`, `WS_PORT_BASE=9311`) | `3` (parallel workspaces) | public + `host.docker.internal` `/32` (`extra_hosts: host-gateway`, `EGRESS_ALLOW_RANGES=host.docker.internal`) |

The split keeps the fixture-site seam out of the browser that loads real job pages: with the old shared service, the
dev browser could reach every RFC1918 range (the developer's LAN, the staging host) and with a `/32` still the
docker host's own services (Elasticsearch, Grafana, Postgres ports). Check: `curl -s localhost:9300/health`,
`curl -s localhost:9310/health`, `curl -s -H 'Authorization: Bearer dev-browserd-token' localhost:9300/health/deep`.

- Conductor workspaces share the pair started by `bin/conductor/conductor_helpers.rb#compose_up!` (root checkout's
  compose project). `bin/conductor/setup.rb#write_env_files` writes `BROWSERD_URL=http://localhost:9300` to
  `.env.development.local` and `BROWSERD_URL=http://localhost:9310` to `.env.test.local`, both with
  `BROWSERD_TOKEN=dev-browserd-token`. (It only appends missing keys: a workspace created before the split keeps
  `:9300` in `.env.test.local` until edited by hand.) In the test env `BROWSERD_URL` switches the `:browser` specs on
  (`spec/support/browser_tag.rb`), so a stopped container makes them fail loudly instead of silently skipping. To
  run without browserd: `BROWSERD_URL= bundle exec rspec`.
- Leases are tagged with `Browserd.owner_prefix` = hostname + workspace dir + env, so one workspace's boot sweep never
  releases another workspace's leases, and `bin/dev` never releases its own workspace's spec leases.
- Outside Conductor put the same variables in `.env` / `.env.test.local` (README "Local Development").

### CI (`.github/workflows/ci.yml`)

- The `test` job sets no `BROWSERD_URL`, so `:browser` examples are excluded there.
- The `browser_specs` job **builds** the image from `docker/browserd` (`docker/build-push-action@v6`,
  `platforms: linux/amd64`, `push: false`, `load: true`, tag `apply_mate_browserd:ci`, GHA layer cache), starts it
  with `docker run` (same flags as compose's `browserd-test` on the default ports 9300-9303, `--pids-limit 2048`,
  `MAX_BROWSERS=1`, `BROWSERD_ADVERTISE_HOST=localhost`, `EGRESS_ALLOW_RANGES=host.docker.internal`), waits up to
  60 s for `/health`, then runs `bundle exec rspec --tag browser` with
  `BROWSERD_URL=http://localhost:9300`, `BROWSERD_TOKEN=ci-token-0123456789` (browserd rejects tokens under 16
  characters) and `FIXTURE_SITE_HOST=host.docker.internal`. `docker logs browserd` runs on every outcome.
- Why not a `services:` container: a service needs a registry image and would not verify the Dockerfile. Building it
  makes a Dockerfile break fail CI and keeps the owner's manual registry push out of CI's dependencies.
- Postgres and Elasticsearch are services as in `test`: `Vacancy` indexes itself on save
  (`Elasticsearch::Model::Callbacks`) and the apply `:browser` specs create vacancies.

### Staging (Kamal accessory `browserd`, `config/deploy.staging.yml`)

`config/deploy.staging.yml` is ERB. `<% apply_slots = 3 %>` at the top is the single source for the `apply_worker`
role's `APPLY_SLOTS` (Solid Queue threads) and the accessory's `MAX_BROWSERS`.

| What | Value |
| --- | --- |
| Accessory image | `andriano606/apply_mate_browserd:156.0.1-beta.36-pw1.63.0-r2` (pulled; the owner pushes it) |
| Accessory options | `network-alias: browserd`, `init`, `memory: 6g`, `memory-swap: 6g`, `cpus: '3'`, `pids-limit: 2048`, `shm-size: 1g`, `tmpfs: /tmp:rw,size=1g`, `cap-add: NET_ADMIN`, `restart: unless-stopped` |
| Accessory ports | none published: control API and ws ports are reachable only on the Kamal network |
| Accessory env | `MAX_BROWSERS: apply_slots (3)`, `LEASE_TTL_S: 1800` (the maximum; each lease asks for its own `ttl_s`), `PORT: 9300`, `HEADLESS: true`, `BROWSERD_OS: windows`, `BROWSERD_ADVERTISE_HOST: browserd`, secret `BROWSERD_TOKEN`; **no** `EGRESS_ALLOW_RANGES` |
| `apply_worker` role | `APPLY_SLOTS: apply_slots (3)`, `BROWSERD_URL: http://browserd:9300`, secret `BROWSERD_TOKEN`, `memory: 3g` |
| `apply_worker` stop window | role key `stop_timeout: 45` |
| Other roles | no `BROWSERD_URL` (only the apply worker leases browsers) |

Sizing (design §18): Raspberry Pi 5, 16 GB → `APPLY_SLOTS = 3`; the 4 CPU cores are the limit, not RAM. browserd gets
6 GB without swap and 3 cores; the apply worker 3 GB. browserd itself refuses `MAX_BROWSERS > 3`.

Resource model of the apply worker: `APPLY_SLOTS` Camoufox leases in browserd (6 GB, 3 cores) plus AT MOST ONE local
Chrome in the apply worker process. Two things launch one there, and both run under the same process-wide slot
`ApplyMate::Client::LocalChrome::SLOT` (`Concurrent::Semaphore(1)`): GeminiScraping (a browser-backed AI client, may
be asked inside a lease) and the Grover PDF render of `Apply::Ai::ResponseSchema::GenerateCv` (every apply's CV step
and `VacancyCv::Job::Create`; all AI/Grover jobs run on `:apply`, i.e. in this one process). Playwright clients are
websocket connections to browserd (`connect_to_browser_server`), not local browsers.

Fit check of the `apply_worker` container (`memory: 3g`, no swap), ESTIMATES (not measured on the Pi): Rails with
`APPLY_SLOTS = 3` job threads about 0.5–0.7 GB, plus the one local Chrome: GeminiScraping on gemini.google.com
about 0.6–1 GB, a Grover CV render about 0.2–0.4 GB; peak ≈ 1.7 GB, ≥ 1.3 GB headroom. Without the shared slot the
worst case was one GeminiScraping Chrome + two Grover Chromiums (≈ 2.5 GB with Rails), close enough to 3 GB for an OOM
SIGKILL (leaked leases until the boot sweep, every in-flight run reaped). Host: browserd 6 GB + apply worker 3 GB are
hard caps; the remaining ≈ 7 GB of the 16 GB hold web, the general worker, Postgres, Elasticsearch (256 MB heap),
MinIO, Loki/Promtail/Grafana and the OS. Measure `docker stats` peaks after the first slow-AI applies and revisit
the 3 GB if Rails alone exceeds 1 GB. See apply_engine.md "Latency-aware budgets". A lease asks for `ttl_s = scope deadline - now + 60 s`
(`Session.open`, clamped by browserd to `60..LEASE_TTL_S`); the scope's deadline is capped at `expires_at - 60 s`, so a
short server maximum ends a scope cleanly. Raise `LEASE_TTL_S` (max 3600) when the slow-AI allowance needs a longer
scope.

`pids-limit` counts **threads** (cgroup `pids`), not processes. Measured 2026-10-07 on `browserd-test` (amd64) with
3 concurrent leases on iframe-heavy pages (reCAPTCHA demo, YouTube, Ashby): `pids.peak` = 564 (~40 idle: node,
smokescreen, tini; ~175 per Camoufox with its content/socket/utility processes). The design's 512 (sized for 2
slots) would make Firefox fail `pthread_create`/fork under full load (content-process crashes → `Crashed`); 2048
leaves ~3.5× headroom and still stops a runaway fork loop. Re-measure (`cat /sys/fs/cgroup/pids.peak` in the
container) when raising `MAX_BROWSERS` or bumping Camoufox.

**Stop window.** Kamal 2.12 stops a role's old container with `docker stop -t <Role#stop_timeout>`
(`Kamal::Configuration::Role#stop_args`: role `stop_timeout`, else top-level `stop_timeout`, else `drain_timeout`
(30 s) for roles without kamal-proxy). The apply worker needs `SolidQueue.shutdown_timeout` (30 s,
`config/initializers/solid_queue_shutdown.rb`) plus 10 s for the running step's `ensure` to release its lease, so
`apply_worker` sets `stop_timeout: 45`. `deploy_timeout`/`drain_timeout` do not bound SIGTERM → SIGKILL for a
proxy-less role. Leases that still leak (SIGKILL, OOM) are freed by the `SolidQueue.on_start` sweep of the next boot
and by the browserd reaper.

**Token.** `BROWSERD_TOKEN` comes from the staging credentials (`browserd.token`) through `.kamal/secrets.staging`,
like the MinIO secrets. Generate it with `openssl rand -hex 32`. Rotation: change `browserd.token`
(`bin/rails credentials:edit --environment staging`), then `bin/kamal accessory reboot browserd -d staging` and
`bin/kamal deploy -d staging --roles=apply_worker` (until the redeploy, `POST /leases` answers 401 and `AcquireLease`
raises `Crashed`).

**Image publishing (owner only).** CI never pushes, and CI is the only place that builds the current
`docker/browserd/` code (`apply_mate_browserd:ci`); dev compose and the staging accessory run whatever image the pinned
tag names. So ANY change under `docker/browserd/` (not only a version bump) bumps the tag: `ARG BROWSERD_REVISION` in
the Dockerfile (`r2` = per-lease `ttl_s`) together with `docker-compose.yml`, `config/deploy.staging.yml` and README
(`spec/config/browserd_image_tag_spec.rb` checks they agree). An unchanged tag is never re-pulled, and the old server
silently ignores fields it does not know (an `r1` server ignores `ttl_s`: every lease lives `LEASE_TTL_S`). After bumping, the owner builds and pushes the
multi-arch image (`docker buildx build --platform linux/amd64,linux/arm64 -t
andriano606/apply_mate_browserd:<triple> --push docker/browserd`, README "browserd"), then reboots the accessory and
redeploys `apply_worker`. Pushing must happen before the deploy, or the accessory boot fails to pull.

## Deviations from design §9.1 (Ruby side)

- **`new_context` without options** instead of `new_context(locale:, timezone_id:)`: Camoufox sets locale, timezone
  and the whole fingerprint at the C++ level per launch (`BROWSERD_LOCALE`, `TZ`); Playwright context overrides would
  contradict it.
- **Challenge predicate:** `Response.cloudflare_interstitial?` (`CLOUDFLARE_MARKERS` minus `challenge-platform`), not
  `cloudflare_challenge?`. Cloudflare injects `/cdn-cgi/challenge-platform/scripts/jsd/main.js` into ordinary 200
  pages (seen on discord.com); on rendered HTML the full marker list would make every such page wait the whole 40 s
  and report a failed challenge. The interstitial always carries `Just a moment` (title) or `cf-chl-`/`_cf_chl_opt`.
- **No `Locator` class:** resolution is `Operation::Locate`; `WaitReady` takes the root `target:` (not a locator)
  because a late-rendering root must be re-located on every poll.
- **Probe signatures** (phase 3a): `snapshot.js` is `(root, { regions })` and `detect.js` is `(root, { markers })`,
  both called from `SnapshotAll::FRAME_JS` with one `{ markers, regions }` argument; without `regions` every element's
  `'regions'` is empty and the form-root / excluded-autofill classification silently does nothing. The `f<i>` part of
  the fingerprint is added in Ruby (`SnapshotAll`), since one JS expression runs in every frame. A child frame's `iframe#id` hop comes from `frame.frame_element` (exact, cross-origin safe),
  not from matching the parent's `iframe_srcs` (a frame's URL changes after an in-frame navigation, its `src` does
  not).
- **`dom_mark`** returns per-container counts (`containers`) besides `option_count`: a count per frame alone cannot
  tell a newly opened listbox from an old one that shifted in DOM order.
- **No `Driver#wait_for_function`**: nothing calls it (`wait_until` polls a Ruby block, `WaitReady` re-locates the
  root each poll); it arrives with its first caller.
- **`mask_fillable`** masks in every frame (up to `MAX_FRAMES`), not only first-level iframes.

## Deviations from design §9.3

- **`geoip: false` + `TZ=Europe/Kyiv`** instead of `geoip: true`. geoip makes node call a public-IP service, and node
  has no egress by design; parity with the attached config, which also runs with geoip off.
- **One uid for node and Firefox** (`browserd`) instead of a separate `camou` uid. Playwright spawns the browser as
  its own uid; a second uid would need setuid/fd/profile-permission plumbing. The guarantee is the same: that uid can
  reach only smokescreen and its own 127.0.0.1-only Playwright upstreams, and only `egress` has outbound network.
- **Playwright server on `127.0.0.1:<fixed per-slot port>`** (not `0.0.0.0:0`), behind browserd's own ws proxy on
  the published port. The fixed range is what lets the firewall allow node → upstream and nothing else; the proxy is
  where connections are counted and the one-client rule is enforced.
- **No per-`identity` fingerprint cache** yet: every lease gets a fresh random fingerprint. `identity` is stored and
  echoed only.
- **No `ws` dependency:** the lease proxy pipes raw TCP after validating the upgrade request, which keeps the
  Playwright protocol byte-exact.
- **uBlock Origin pre-installed** (pinned xpi): camoufox-js loads it by default, and fetching it at runtime is
  impossible without egress (a failed fetch would leave an empty addon dir that breaks every later launch).
