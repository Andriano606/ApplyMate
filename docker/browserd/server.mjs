// browserd: hands out short-lived Camoufox browsers ("leases") to the Rails apply worker.
// Full reference: .ai/docs/browser.md. Started by entrypoint.sh as uid `browserd` after the
// egress firewall and the smokescreen proxy are up.
//
// Environment (validated at boot; invalid values exit 1):
//   PORT                    control API port (default 9300)
//   BROWSERD_TOKEN          REQUIRED, >= 16 chars. Bearer token for every route but GET /health
//   MAX_BROWSERS            REQUIRED, integer 1..3 (= the published ws port range 9301-9303).
//                           Hard cap on concurrent browsers; staging sets it to APPLY_SLOTS.
//   LEASE_TTL_S             longest lifetime of one lease in seconds (default 1800, 60..3600). A POST /leases
//                           may ask for less with ttl_s (clamped to 60..LEASE_TTL_S); without it a lease gets this.
//   HEADLESS                true | virtual | false (default true). virtual = headful under the
//                           Xvfb display entrypoint.sh starts (DISPLAY=:99)
//   BROWSERD_OS             fingerprint OS: windows | macos | linux (default windows)
//   BROWSERD_LOCALE         browser locale (default uk-UA)
//   BROWSERD_ADVERTISE_HOST host put into ws_endpoint (default os.hostname())
//   WS_PORT_BASE            first per-lease ws port (default 9301); slot n listens on base+n,
//                           its 127.0.0.1-only Playwright upstream on base+10+n
//   PROXY_URL               egress proxy every browser uses (default http://127.0.0.1:4750)
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import crypto from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import { launchServer, launchOptions } from 'camoufox-js';
import { firefox } from 'playwright-core';
import { LeaseTable } from './leases.mjs';
import { startLeaseProxy, closeLeaseProxy } from './lease_proxy.mjs';
import { launchSettings, versions } from './camoufox.mjs';

const REAPER_INTERVAL_MS = 15_000;
const LAUNCH_TIMEOUT_MS = 60_000;
const CLOSE_GRACE_MS = 5_000;
const KILL_WAIT_MS = 5_000;
const SHUTDOWN_CAP_MS = 8_000;
const DEEP_HEALTH_CAP_MS = 20_000;
const PROXY_PROBE_TIMEOUT_MS = 1_000;
const PROXY_FAILURES_BEFORE_EXIT = 4;
const MAX_BODY_BYTES = 16 * 1024;
const MAX_FIELD_LENGTH = 200;
const RETRY_AFTER_S = 5;
const DEEP_HEALTH_OWNER = 'browserd:health-deep';

function log(level, msg, fields = {}) {
  process.stdout.write(
    `${JSON.stringify({ ts: new Date().toISOString(), level, msg, ...fields })}\n`,
  );
}

function fail(message) {
  log('fatal', message);
  process.exit(1);
}

function intEnv(env, name, fallback, { min, max }) {
  const raw =
    env[name] ?? (fallback === undefined ? undefined : String(fallback));
  if (raw === undefined || raw === '') fail(`${name} is required`);
  if (!/^\d+$/.test(raw))
    fail(`${name} must be an integer, got ${JSON.stringify(raw)}`);
  const value = Number(raw);
  if (value < min || value > max)
    fail(`${name} must be within ${min}..${max}, got ${value}`);
  return value;
}

function oneOf(env, name, fallback, allowed) {
  const value = env[name] || fallback;
  if (!allowed.includes(value))
    fail(
      `${name} must be one of ${allowed.join('|')}, got ${JSON.stringify(value)}`,
    );
  return value;
}

function readConfig(env) {
  const token = env.BROWSERD_TOKEN ?? '';
  if (token.length < 16) fail('BROWSERD_TOKEN is required (>= 16 chars)');

  let proxyUrl;
  try {
    proxyUrl = new URL(env.PROXY_URL || 'http://127.0.0.1:4750');
  } catch {
    fail(`PROXY_URL is not a URL: ${JSON.stringify(env.PROXY_URL)}`);
  }

  return {
    port: intEnv(env, 'PORT', 9300, { min: 1, max: 65535 }),
    token,
    maxBrowsers: intEnv(env, 'MAX_BROWSERS', undefined, { min: 1, max: 3 }),
    ttlSeconds: intEnv(env, 'LEASE_TTL_S', 1800, { min: 60, max: 3600 }),
    wsPortBase: intEnv(env, 'WS_PORT_BASE', 9301, { min: 1024, max: 65000 }),
    advertiseHost: env.BROWSERD_ADVERTISE_HOST || os.hostname(),
    proxyUrl,
    browser: {
      headlessMode: oneOf(env, 'HEADLESS', 'true', [
        'true',
        'virtual',
        'false',
      ]),
      os: oneOf(env, 'BROWSERD_OS', 'windows', ['windows', 'macos', 'linux']),
      locale: env.BROWSERD_LOCALE || 'uk-UA',
      proxyUrl: proxyUrl.href,
      display: env.DISPLAY,
    },
  };
}

const config = readConfig(process.env);
const { playwrightCore, camoufoxBuild } = versions();
const table = new LeaseTable({
  maxBrowsers: config.maxBrowsers,
  ttlSeconds: config.ttlSeconds,
  wsPortBase: config.wsPortBase,
});
const tokenDigest = crypto.createHash('sha256').update(config.token).digest();

// id -> { browserServer, proxy: { server, sockets } } for leases that have a browser.
const runtime = new Map();
// id -> teardown promise, so DELETE / reaper / process exit kill each browser once.
const releases = new Map();
let shuttingDown = false;
let proxyFailures = 0;
let proxyProbe = null;
let deepHealth = null;

// ---------------------------------------------------------------- helpers

function authorized(req) {
  const header = req.headers.authorization ?? '';
  if (!header.startsWith('Bearer ')) return false;
  const digest = crypto
    .createHash('sha256')
    .update(header.slice('Bearer '.length))
    .digest();
  return crypto.timingSafeEqual(digest, tokenDigest);
}

function sendJson(res, status, body, headers = {}) {
  if (res.headersSent || res.destroyed) return;
  const payload = body === undefined ? '' : JSON.stringify(body);
  res.writeHead(status, {
    ...(payload ? { 'Content-Type': 'application/json' } : {}),
    'Content-Length': Buffer.byteLength(payload),
    'Cache-Control': 'no-store',
    ...headers,
  });
  res.end(payload);
}

class HttpError extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
    this.code = code;
  }
}

async function readJson(req) {
  const declared = Number(req.headers['content-length'] ?? 0);
  if (declared > MAX_BODY_BYTES) throw new HttpError(413, 'body_too_large');

  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new HttpError(413, 'body_too_large');
    chunks.push(chunk);
  }
  if (size === 0) return {};
  try {
    const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed))
      throw new Error('not an object');
    return parsed;
  } catch {
    throw new HttpError(400, 'invalid_json');
  }
}

function boundedString(value, name, { required }) {
  if (value === undefined || value === null) {
    if (required) throw new HttpError(422, `${name}_required`);
    return null;
  }
  if (
    typeof value !== 'string' ||
    value.length === 0 ||
    value.length > MAX_FIELD_LENGTH
  ) {
    throw new HttpError(422, `${name}_invalid`);
  }
  return value;
}

function withTimeout(promise, ms) {
  return Promise.race([
    promise,
    sleep(ms).then(() => {
      throw new Error(`timed out after ${ms} ms`);
    }),
  ]);
}

function processAlive(proc) {
  return proc.exitCode === null && proc.signalCode === null;
}

// ---------------------------------------------------------------- egress proxy probe

function connectProbe() {
  return new Promise((resolve) => {
    const socket = net.connect({
      host: config.proxyUrl.hostname,
      port: Number(config.proxyUrl.port || 80),
    });
    const done = (ok) => {
      socket.destroy();
      resolve(ok);
    };
    socket.setTimeout(PROXY_PROBE_TIMEOUT_MS, () => done(false));
    socket.once('connect', () => done(true));
    socket.once('error', () => done(false));
  });
}

// Shared by GET /health and the reaper tick. Leases must never run without the egress
// proxy, so PROXY_FAILURES_BEFORE_EXIT consecutive failures exit the process and the
// container restart policy brings the whole stack (firewall + proxy + node) back.
function probeProxy() {
  proxyProbe ??= connectProbe().then((ok) => {
    proxyProbe = null;
    proxyFailures = ok ? 0 : proxyFailures + 1;
    if (!ok)
      log('error', 'egress_proxy_unreachable', { consecutive: proxyFailures });
    if (proxyFailures >= PROXY_FAILURES_BEFORE_EXIT)
      shutdown(1, 'egress_proxy_down');
    return ok;
  });
  return proxyProbe;
}

// ---------------------------------------------------------------- lease lifecycle

// Bounded: close() gets CLOSE_GRACE_MS, then kill() gets KILL_WAIT_MS, then SIGKILL. The
// slot is freed afterwards no matter what, so a hung browser cannot pin a slot forever
// (teardown also caps closeLeaseProxy at CLOSE_GRACE_MS).
async function stopBrowser(browserServer) {
  const proc = browserServer.process();
  if (!processAlive(proc)) return;

  await Promise.race([
    browserServer.close().catch(() => {}),
    sleep(CLOSE_GRACE_MS),
  ]);
  if (!processAlive(proc)) return;

  await Promise.race([
    browserServer.kill().catch(() => {}),
    sleep(KILL_WAIT_MS),
  ]);
  if (processAlive(proc)) {
    proc.kill('SIGKILL');
    log('error', 'browser_kill_unconfirmed', { pid: proc.pid });
  }
}

async function teardown(lease, reason) {
  const rt = runtime.get(lease.id);
  try {
    if (rt?.proxy && !(await closeLeaseProxy(rt.proxy, CLOSE_GRACE_MS)))
      log('error', 'lease_proxy_close_timeout', { id: lease.id });
    if (rt?.browserServer) await stopBrowser(rt.browserServer);
  } catch (error) {
    log('error', 'lease_teardown_failed', {
      id: lease.id,
      error: String(error),
    });
  } finally {
    runtime.delete(lease.id);
    table.release(lease.id);
    log('info', 'lease_released', {
      id: lease.id,
      owner: lease.owner,
      reason,
      lived_ms: Date.now() - lease.createdAt,
      ...table.toHealth(),
    });
  }
}

// `lease` must already be in state 'releasing' (LeaseTable#beginRelease).
function startTeardown(lease, reason) {
  const pending = teardown(lease, reason).finally(() =>
    releases.delete(lease.id),
  );
  releases.set(lease.id, pending);
  return pending;
}

// Releases an active lease. Returns the teardown promise (shared when one is already
// running) or null for unknown / still-launching leases.
function releaseLease(id, reason) {
  const pending = releases.get(id);
  if (pending) return pending;

  const lease = table.get(id);
  if (!lease || lease.state !== 'active') return null;

  table.beginRelease(id);
  return startTeardown(lease, reason);
}

async function createLease(owner, humanize, identity, ttlSeconds, req) {
  const lease = table.acquire(owner, { humanize, identity, ttlSeconds });
  if (!lease) return null;

  const wsPath = crypto.randomBytes(32).toString('hex');
  try {
    const browserServer = await launchServer({
      ...launchSettings(config.browser, { humanize }),
      host: '127.0.0.1',
      port: lease.upstreamPort,
      ws_path: wsPath,
      timeout: LAUNCH_TIMEOUT_MS,
    });
    runtime.set(lease.id, { browserServer, proxy: null });
    const proc = browserServer.process();
    proc.once('exit', (code, signal) => {
      table.markProcessExit(lease.id);
      log('info', 'browser_exited', { id: lease.id, code, signal });
      releaseLease(lease.id, 'process_exit');
    });
    if (!processAlive(proc)) throw new Error('browser exited during launch');

    runtime.get(lease.id).proxy = await startLeaseProxy({
      lease,
      wsPath,
      onConnection: (delta) => table.markConnected(lease.id, delta),
      log,
    });
    if (!processAlive(proc)) throw new Error('browser exited during launch');
    if (shuttingDown) throw new Error('shutting down');
    if (req.socket.destroyed) throw new Error('client went away during launch');
  } catch (error) {
    log('error', 'lease_launch_failed', {
      id: lease.id,
      owner,
      error: String(error),
    });
    table.beginRelease(lease.id);
    await startTeardown(lease, 'launch_failed');
    throw new HttpError(500, 'launch_failed');
  }

  table.markReady(lease.id);
  log('info', 'lease_created', {
    id: lease.id,
    owner,
    slot: lease.slot,
    humanize,
    ...table.toHealth(),
  });
  return {
    id: lease.id,
    ws_endpoint: `ws://${config.advertiseHost}:${lease.port}/${wsPath}`,
    expires_at: new Date(lease.expiresAt).toISOString(),
    playwright_version: playwrightCore,
    browser_version: camoufoxBuild,
    identity,
  };
}

function reap() {
  for (const { lease, reason } of table.reapable()) {
    log('info', 'lease_reaped', { id: lease.id, owner: lease.owner, reason });
    releaseLease(lease.id, reason);
  }
  probeProxy();
}

// Launches a throwaway browser under a lease slot (so MAX_BROWSERS also caps health
// checks) and opens about:blank. One check at a time; the whole run is capped.
function runDeepHealth() {
  deepHealth ??= (async () => {
    const lease = table.acquire(DEEP_HEALTH_OWNER);
    if (!lease) return { status: 503, body: { ok: false, error: 'pool_busy' } };

    const started = Date.now();
    let browser = null;
    try {
      const options = await launchOptions(launchSettings(config.browser));
      browser = await firefox.launch({
        ...options,
        timeout: DEEP_HEALTH_CAP_MS / 2,
      });
      const page = await browser.newPage();
      await page.goto('about:blank', {
        timeout: Math.max(1_000, DEEP_HEALTH_CAP_MS - (Date.now() - started)),
      });
      return {
        status: 200,
        body: {
          ok: true,
          ms: Date.now() - started,
          browser: browser.version(),
        },
      };
    } catch (error) {
      log('error', 'deep_health_failed', { error: String(error) });
      return {
        status: 503,
        body: {
          ok: false,
          ms: Date.now() - started,
          error: String(error.message ?? error),
        },
      };
    } finally {
      if (browser)
        await Promise.race([
          browser.close().catch(() => {}),
          sleep(CLOSE_GRACE_MS),
        ]);
      table.release(lease.id);
    }
  })().finally(() => {
    deepHealth = null;
  });
  return deepHealth;
}

// ---------------------------------------------------------------- routes

async function handle(req, res) {
  const url = new URL(req.url, 'http://browserd');
  const leaseIdMatch = url.pathname.match(/^\/leases\/([0-9a-f-]{36})$/);

  if (req.method === 'GET' && url.pathname === '/health') {
    const proxyOk = await probeProxy();
    const ok = proxyOk && !shuttingDown;
    return sendJson(res, ok ? 200 : 503, {
      ok,
      ...table.toHealth(),
      playwright_core: playwrightCore,
      camoufox_build: camoufoxBuild,
      proxy_ok: proxyOk,
    });
  }

  if (!authorized(req))
    return sendJson(
      res,
      401,
      { error: 'unauthorized' },
      { 'WWW-Authenticate': 'Bearer' },
    );

  if (req.method === 'GET' && url.pathname === '/health/deep') {
    const { status, body } = await runDeepHealth();
    return sendJson(res, status, body);
  }

  if (req.method === 'POST' && url.pathname === '/leases') {
    if (shuttingDown)
      return sendJson(
        res,
        503,
        { error: 'shutting_down' },
        { 'Retry-After': String(RETRY_AFTER_S) },
      );
    const body = await readJson(req);
    const owner = boundedString(body.owner, 'owner', { required: true });
    const identity = boundedString(body.identity, 'identity', {
      required: false,
    });
    if (body.humanize !== undefined && typeof body.humanize !== 'boolean')
      throw new HttpError(422, 'humanize_invalid');
    if (
      body.ttl_s !== undefined &&
      (!Number.isInteger(body.ttl_s) || body.ttl_s < 1)
    )
      throw new HttpError(422, 'ttl_invalid');

    const lease = await createLease(
      owner,
      body.humanize === true,
      identity,
      body.ttl_s,
      req,
    );
    if (!lease) {
      return sendJson(
        res,
        503,
        { error: 'pool_busy', ...table.toHealth() },
        { 'Retry-After': String(RETRY_AFTER_S) },
      );
    }
    return sendJson(res, 201, lease);
  }

  if (req.method === 'DELETE' && leaseIdMatch) {
    const lease = table.get(leaseIdMatch[1]);
    if (!lease) return sendJson(res, 404, { error: 'not_found' });
    if (lease.state === 'launching')
      return sendJson(res, 409, { error: 'launching' });

    await releaseLease(lease.id, 'deleted');
    return sendJson(res, 204);
  }

  if (req.method === 'DELETE' && url.pathname === '/leases') {
    const prefix = url.searchParams.get('owner');
    if (!prefix) throw new HttpError(400, 'owner_required');

    const leases = table.releaseByOwnerPrefix(prefix);
    await Promise.all(
      leases.map((lease) => startTeardown(lease, 'owner_cleanup')),
    );
    return sendJson(res, 200, { released: leases.length });
  }

  return sendJson(res, 404, { error: 'not_found' });
}

// ---------------------------------------------------------------- process lifecycle

async function shutdown(code, reason) {
  if (shuttingDown) return;
  shuttingDown = true;
  clearInterval(reaperTimer);
  log(code === 0 ? 'info' : 'fatal', 'shutting_down', {
    reason,
    ...table.toHealth(),
  });

  const active = table.all().filter((lease) => lease.state === 'active');
  const pending = [
    ...active.map((lease) => releaseLease(lease.id, 'shutdown')),
    ...releases.values(),
  ];
  await Promise.race([Promise.allSettled(pending), sleep(SHUTDOWN_CAP_MS)]);
  process.exit(code);
}

const server = http.createServer((req, res) => {
  handle(req, res).catch((error) => {
    if (error instanceof HttpError)
      return sendJson(res, error.status, { error: error.code });
    log('error', 'request_failed', {
      method: req.method,
      path: req.url.split('?')[0],
      error: String(error),
    });
    return sendJson(res, 500, { error: 'internal_error' });
  });
});

const reaperTimer = setInterval(reap, REAPER_INTERVAL_MS);

process.on('SIGTERM', () => shutdown(0, 'SIGTERM'));
process.on('SIGINT', () => shutdown(0, 'SIGINT'));
process.on('unhandledRejection', (error) =>
  log('error', 'unhandled_rejection', { error: String(error) }),
);
process.on('uncaughtException', (error) => {
  log('fatal', 'uncaught_exception', {
    error: String(error),
    stack: error.stack,
  });
  shutdown(1, 'uncaught_exception');
});

server.listen(config.port, '0.0.0.0', () => {
  log('info', 'browserd_listening', {
    port: config.port,
    max_browsers: config.maxBrowsers,
    lease_ttl_s: config.ttlSeconds,
    ws_ports: `${config.wsPortBase}-${config.wsPortBase + config.maxBrowsers - 1}`,
    headless: config.browser.headlessMode,
    os: config.browser.os,
    locale: config.browser.locale,
    advertise_host: config.advertiseHost,
    playwright_core: playwrightCore,
    camoufox_build: camoufoxBuild,
  });
});
