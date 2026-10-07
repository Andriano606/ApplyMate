# Browser layer: browserd and Camoufox

How the apply engine gets a real browser: the `browserd` container hands out short-lived Camoufox (Firefox) browsers
("leases") over the Playwright protocol. Read before touching `docker/browserd/`, the browser Session/Driver/NetTracker/Locate or
`ApplyMate::Net::Operation::ResolvePublicAddress` (PublicAddressGuard).

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

**Image tag (single source):** `andriano606/apply_mate_browserd:156.0.1-beta.36-pw1.63.0`, used by
`docker-compose.yml`, CI and Kamal. Bump the Dockerfile ARGs, `package.json` + lockfile and the tag together.

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
| `LEASE_TTL_S` | `600` (60..3600) | Hard lifetime of one lease |
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
| `POST /leases` `{"owner": "<host>:<app dir>:<env>:<pid>:<apply hashid>", "humanize": false, "identity": null}` (JSON ≤ 16 KB; `owner` required, 1..200 chars; `identity` optional string) | `201` `{id, ws_endpoint: "ws://<ADVERTISE_HOST>:<9301+slot>/<64 hex>", expires_at, playwright_version, browser_version, identity}`; `503` + `Retry-After: 5` + `{error: "pool_busy", leases, max}` when all slots are taken (or `shutting_down`); `500 {error: "launch_failed"}`; `400 invalid_json`, `413 body_too_large`, `422 owner_required / owner_invalid / identity_invalid / humanize_invalid` |
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
| TTL | `now ≥ expires_at` (`LEASE_TTL_S` from readiness) |
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
model = `Resolution` (`Data.define(:url, :host, :port, :ip)`, `ip` = first address).

1. `URI.parse`; the scheme must be `http`/`https` and the host present, else `UnsafeUrlError` reason `:scheme`
   (also for unparsable URLs).
2. A literal IP is used as is (no DNS). A hostname goes through
   `Resolv.new([Resolv::Hosts.new, Resolv::DNS.new` with `timeouts = 3`)`.getaddresses`. No answers → `:unresolvable`
   (this also catches browser-only IP spellings such as `http://2130706433/`).
3. **Every** address must be public, else `:private`. One private answer among public ones is rejected (DNS
   rebinding mix). An answer `IPAddr` cannot parse (e.g. scoped `fe80::1%lo`) counts as private.

`BLOCKED_RANGES`: `0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24
192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4 ::/128 ::1/128 fc00::/7 fe80::/10`. IPv4-mapped IPv6
(`::ffff:0:0/96`) is unwrapped and its IPv4 checked.

`ApplyMate::Net::UnsafeUrlError` (`reason` ∈ `:scheme :unresolvable :private`, `url`) names only the host in its
message; the full URL may carry tokens. The Runner maps it to the code `private_address` (`unsupported`), wired in
phase 2 unit 4. Pinning the checked IP into `ImpersonateHttp` via curl `--resolve` is deferred to phase 3a (see
"Deferred to phase 3a"); `Resolution#ip` exists for it. The browser itself is covered by smokescreen (see Network
isolation); the guard is the Ruby-side check before navigation.

## Session API

Code: `app/concepts/apply_mate/client/browser/session.rb` (facade), `driver/playwright.rb` (the only driver),
`net_tracker.rb`, `target.rb`, `nav_result.rb`, `clock.rb`, `probe/*.js`, and the algorithms as internal operations in
`operation/` (`Goto`, `WaitPastCloudflare`, `WaitForContentSettle`, `WaitQuiet`, `Locate`, `WaitReady`).

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
`deadline` is a `Time` (the Runner's scope deadline, `SCOPE_DEADLINE` on `Apply::Operation::Engine::Context`, phase 2
unit 4). `Session.owner_for(apply)` = `"<Browserd.owner_prefix><pid>:<apply hashid>"`.

`Driver#start`: `Playwright.connect_to_browser_server(ws_endpoint, browser_type: 'firefox')` (bounded by
`CONNECT_TIMEOUT_S = 30`), `browser.new_context` **without options**, `new_page`, `NetTracker.new(page)`.

| Method | Visibility | Does |
|---|---|---|
| `goto(url)` | — | `Operation::Goto` → `NavResult(status, final_url, challenge_passed, was_challenge)` |
| `click(target)` | `:required` | `locator.click` (trusted input, Playwright actionability waits) |
| `fill(target, text)` | `:required` | `locator.fill` |
| `press(target, key)` | `:required` | `locator.press` |
| `select(target, value: nil, label: nil)` | `:required` | `locator.select_option` |
| `set_checked(target, value)` | `:attached` | `locator.set_checked` |
| `upload(target, path, via_chooser: false)` | `:attached` (`:required` with `via_chooser`) | `set_input_files(path)`, or `expect_file_chooser { target.click }.set_files(path)`; files stream over the protocol |
| `probe(name, target, arg = nil)` | `:attached` | `locator.evaluate(PROBES[name], arg)` |
| `present?(target, visibility:)` | given | `Locate`, `TargetNotFound` → `false` |
| `ready?(root_target, timeout:, min_fields: 1)` | `:attached` | `Operation::WaitReady` (`timeout` in seconds) → Boolean |
| `html(frame_path: [])` | — | `page.content`; with a frame path the `outer_html` probe on that frame's `:root` |
| `frames` | — | `[{ 'url', 'name' }]` of every frame |
| `screenshot(full_page: false)` | — | PNG bytes |
| `cookies` | — | `"name=value; …"` of the context |
| `current_url` | — | `page.url` |
| `settle(kind)` | — | `Operation::WaitQuiet` with profile `kind` → `{ quiet:, ms: }` |
| `settle_content` | — | `Operation::WaitForContentSettle` → Boolean |
| `network_mark` / `network_since(mark)` | — | `NetTracker#mark` / `#since` |

Callers today: `Apply::Operation::Ai::FetchExternalForm` (`humanize: false`) and `Apply::Operation::SendApply::Browser`
(`humanize: true`), see `.ai/docs/apply_handlers.md`. Step specs use `FakeSession` (`.ai/docs/rspec.md`), whose
method list and parameters `session_contract_spec.rb` keeps identical to this class.

Methods arrive with their callers: the rest of design §9.1 is listed in "Deferred to phase 3a".

**`Operation::Goto`** (port of `gotoSmart`): `ResolvePublicAddress` (raises `UnsafeUrlError` before any navigation)
→ `driver.navigate(url)` (`waitUntil: 'domcontentloaded'`, `NAVIGATE_TIMEOUT_MS = 30_000`) →
`WaitPastCloudflare(max_ms: 40_000)` → `wait_for_network_idle(8_000)` (a timeout there is fine). A navigation error
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

`Operation::WaitReady.call(driver:, target:, timeout_ms:, min_fields: 1)`: every 250 ms, `Locate(:attached)` the root
and run the `readiness` probe; `true` once it reports `ready`, `false` at `min(timeout_ms, remaining)`. An
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
Events arrive on the gem's reader thread: state lives in `Concurrent::Map` (in flight, keyed by the request object),
`Concurrent::Array` (records) and `Concurrent::AtomicReference` (last event); callbacks never call back into
Playwright (a blocking call from the reader thread deadlocks it) and never raise (that would kill the dispatch loop).

| API | Value |
|---|---|
| `pending(ignore_older_ms: 3_000)` | in-flight requests (any method) younger than `ignore_older_ms`; ignored ones older than `STALE_MS = 60_000` are dropped for good |
| `last_event_at` | monotonic ms of the last request start/finish/failure (`-Infinity` before any) |
| `mark` / `since(mark)` | monotonic ms / records whose request started at or after `mark` |
| `dispose` | unsubscribes (`Driver#close`) |

A record `{ url:, method:, status:, at:, frame_url: }` is written when a **non-GET** request finishes (`status` from
`request.existing_response`) or fails (`status: nil`), unless its host matches `IGNORED_HOSTS` (suffix match; `host/path`
entries also match a path prefix): `google-analytics.com googletagmanager.com doubleclick.net recaptcha.net
gstatic.com/recaptcha google.com/recaptcha hcaptcha.com challenges.cloudflare.com sentry.io segment.io hotjar.com
facebook.net`. At most `MAX_RECORDS = 500`, oldest dropped. Response bodies for `submit_request` come with phase 3a.

All monotonic time comes from `ApplyMate::Client::Browser::Clock` (`now_ms`, `sleep_ms`, `remaining_ms(deadline)`);
unit specs stub it to drive the wait loops.

## Probes

`app/concepts/apply_mate/client/browser/probe/*.js`: one JS function expression per file, run in the element's
(isolated, on Camoufox) world by `locator.evaluate`. `Driver::Playwright::PROBES` reads them once at class load
(leading `//` comment lines and prettier's trailing `;` stripped); no IO per call. Prettier-checked in CI
(`app/**/*.js`).

| Probe | Signature | Returns |
|---|---|---|
| `read_value` | `(el)` | `{ tag, value, checked, files: [names], text }` for input / textarea / select (`text` = selected option) / contenteditable |
| `readiness` | `(root, { min })` | `{ fields, ready }`: visible fillable controls under root, `ready = fields >= min` |
| `snapshot` | `(root)` | minimal: `[{ index, tag, type, name, id, label, placeholder, visible }]` of interactive elements; the full snapshot is phase 3a |
| `outer_html` | `(el)` | `el.outerHTML` (`Session#html(frame_path:)`) |

## Deadlines & errors

Every waiting driver primitive clamps its timeout with `clamp_ms(ms) = [ms, remaining_ms].min` and raises
`DeadlineExceeded` when `remaining_ms <= 0` (`navigate`, `wait_for_network_idle`, `click`, `fill`, `press`,
`select`, `set_checked`, `upload`, `probe`, `evaluate`, `count`, mouse). Timeouts: actions `ACTION_TIMEOUT_MS =
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
| `ApplyMate::Net::UnsafeUrlError` | `Goto` (before navigating) | `private_address`, phase 2 unit 4 |

Any other `Playwright::Error` (navigation failure, an action timing out on a present element) propagates unchanged.

## Dev / CI / staging wiring

The image tag is the pinned triple `<CAMOUFOX_VERSION>-<CAMOUFOX_RELEASE>-pw<playwright-core>`, currently
`156.0.1-beta.36-pw1.63.0`. It is written in the Dockerfile ARGs, `package.json`/`package-lock.json`,
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
| Accessory image | `andriano606/apply_mate_browserd:156.0.1-beta.36-pw1.63.0` (pulled; the owner pushes it) |
| Accessory options | `network-alias: browserd`, `init`, `memory: 6g`, `memory-swap: 6g`, `cpus: '3'`, `pids-limit: 2048`, `shm-size: 1g`, `tmpfs: /tmp:rw,size=1g`, `cap-add: NET_ADMIN`, `restart: unless-stopped` |
| Accessory ports | none published: control API and ws ports are reachable only on the Kamal network |
| Accessory env | `MAX_BROWSERS: apply_slots (3)`, `LEASE_TTL_S: 600`, `PORT: 9300`, `HEADLESS: true`, `BROWSERD_OS: windows`, `BROWSERD_ADVERTISE_HOST: browserd`, secret `BROWSERD_TOKEN`; **no** `EGRESS_ALLOW_RANGES` |
| `apply_worker` role | `APPLY_SLOTS: apply_slots (3)`, `BROWSERD_URL: http://browserd:9300`, secret `BROWSERD_TOKEN`, `memory: 3g` |
| `apply_worker` stop window | role key `stop_timeout: 45` |
| Other roles | no `BROWSERD_URL` (only the apply worker leases browsers) |

Sizing (design §18): Raspberry Pi 5, 16 GB → `APPLY_SLOTS = 3`; the 4 CPU cores are the limit, not RAM. browserd gets
6 GB without swap and 3 cores; the apply worker 3 GB. browserd itself refuses `MAX_BROWSERS > 3`.

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

**Image publishing (owner only).** CI never pushes. After bumping the triple, the owner builds and pushes the
multi-arch image (`docker buildx build --platform linux/amd64,linux/arm64 -t
andriano606/apply_mate_browserd:<triple> --push docker/browserd`, README "browserd"), then reboots the accessory and
redeploys `apply_worker`. Pushing must happen before the deploy, or the accessory boot fails to pull.

## Deferred to phase 3a

Parts of design §9.1/§9.3 that phase 2 does not ship, because their first consumer arrives in phase 3a (adding them
now would be public API no production code calls):

| Item | Design | First consumer |
|---|---|---|
| `ImpersonateHttp` pinned to the guard's checked IP via curl `--resolve host:port:ip` (`Resolution#ip` already returned) | §9.3 PublicAddressGuard | `DetectPlatform` redirect walker, `fetch_schema` (3a). No phase-2 caller fetches an untrusted URL over HTTP: untrusted URLs go only through `Session#goto` (smokescreen) |
| Session `type`, `snapshot_all`, `dom_mark`, `wait_for_listbox(since:, timeout:)`, `pages`, `switch_to(index)`, `scroll_into_view`, `wait_until(timeout:)`, `screenshot(mask_fillable:)` | §9.1 Session | widgets, Navigator, FailureArtifacts (3a/3b) |
| Full `snapshot.js` (phase 2 ships the minimal probe) | §9.1 probes | `Apply::Field` extraction (3a) |
| NetTracker response bodies (≤ 64 KB) for requests matching `success_evidence[:submit_request]` | §9.1 NetTracker | platform DSL + Verifier (3a) |

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
