// Pure lease bookkeeping for browserd: slots, ports, deadlines, connection counts.
// No I/O and no timers, so every rule here is unit-tested in test/leases.test.mjs.
//
// Lifecycle of one lease:
//   acquire()      -> state 'launching', slot + ports reserved (counts against the cap)
//   markReady()    -> state 'active', TTL starts (expiresAt = now + the lease's own ttlMs), never-connected grace starts
//   beginRelease() -> state 'releasing' (still holds the slot: the browser is being killed)
//   release()      -> slot freed; only called once the browser process and proxy are gone
//
// A slot is freed only by release(), so a new lease can never bind the ws/upstream port
// of a browser that is still shutting down. External release paths (DELETE, owner
// cleanup, reaper) only ever touch 'active' leases: a 'launching' lease is owned by the
// POST /leases request that created it, which tears it down itself on any failure.
import crypto from 'node:crypto';

export const DISCONNECT_GRACE_MS = 30_000;
export const NEVER_CONNECTED_GRACE_MS = 60_000;
// Upstream (127.0.0.1-only) Playwright server port = wsPortBase + UPSTREAM_PORT_OFFSET + slot.
// entrypoint.sh opens exactly this range to uid browserd in iptables; keep them in sync.
export const UPSTREAM_PORT_OFFSET = 10;
// Shortest lease a client may ask for (POST /leases ttl_s); the longest is the table's ttlSeconds (LEASE_TTL_S).
export const MIN_TTL_S = 60;

export class LeaseTable {
  constructor({ maxBrowsers, ttlSeconds, wsPortBase }) {
    if (!Number.isInteger(maxBrowsers) || maxBrowsers < 1)
      throw new Error('maxBrowsers must be a positive integer');
    if (!Number.isInteger(ttlSeconds) || ttlSeconds < 1)
      throw new Error('ttlSeconds must be a positive integer');
    if (!Number.isInteger(wsPortBase) || wsPortBase < 1)
      throw new Error('wsPortBase must be a positive integer');

    this.maxBrowsers = maxBrowsers;
    this.ttlMs = ttlSeconds * 1000;
    this.wsPortBase = wsPortBase;
    this.slots = new Array(maxBrowsers).fill(null);
    this.byId = new Map();
  }

  // Returns the new lease, or null when every slot is taken (caller answers 503). meta.ttlSeconds (optional, the
  // client's ttl_s) is clamped to [MIN_TTL_S, ttlSeconds]; without it the lease lives ttlSeconds.
  acquire(owner, meta = {}, now = Date.now()) {
    const slot = this.slots.indexOf(null);
    if (slot === -1) return null;

    const lease = {
      id: crypto.randomUUID(),
      owner,
      meta,
      ttlMs: this.#ttlMs(meta.ttlSeconds),
      slot,
      port: this.wsPortBase + slot,
      upstreamPort: this.wsPortBase + UPSTREAM_PORT_OFFSET + slot,
      state: 'launching',
      createdAt: now,
      readyAt: null,
      expiresAt: null,
      connections: 0,
      everConnected: false,
      lastDisconnectAt: null,
      processExited: false,
    };
    this.slots[slot] = lease;
    this.byId.set(lease.id, lease);
    return lease;
  }

  get(id) {
    return this.byId.get(id) ?? null;
  }

  all() {
    return [...this.byId.values()];
  }

  markReady(id, now = Date.now()) {
    const lease = this.get(id);
    if (!lease || lease.state !== 'launching') return null;

    lease.state = 'active';
    lease.readyAt = now;
    lease.expiresAt = now + lease.ttlMs;
    return lease;
  }

  // Moves a lease to 'releasing'. Returns the lease the first time, null afterwards, so
  // concurrent DELETE / reaper / process-exit paths kill each browser exactly once.
  beginRelease(id) {
    const lease = this.get(id);
    if (!lease || lease.state === 'releasing') return null;

    lease.state = 'releasing';
    return lease;
  }

  // Frees the slot. Returns true when the lease existed.
  release(id) {
    const lease = this.get(id);
    if (!lease) return false;

    this.byId.delete(id);
    if (this.slots[lease.slot] === lease) this.slots[lease.slot] = null;
    return true;
  }

  // Marks every active lease whose owner starts with `prefix` as releasing and returns
  // them; the caller kills each browser and then calls release(id).
  releaseByOwnerPrefix(prefix) {
    if (typeof prefix !== 'string' || prefix.length === 0) return [];

    return this.#active()
      .filter((lease) => lease.owner.startsWith(prefix))
      .map((lease) => this.beginRelease(lease.id));
  }

  markConnected(id, delta, now = Date.now()) {
    const lease = this.get(id);
    if (!lease) return null;

    lease.connections = Math.max(0, lease.connections + delta);
    if (delta > 0) lease.everConnected = true;
    if (delta < 0 && lease.connections === 0) lease.lastDisconnectAt = now;
    return lease;
  }

  markProcessExit(id) {
    const lease = this.get(id);
    if (!lease) return null;

    lease.processExited = true;
    return lease;
  }

  #ttlMs(requested) {
    if (requested === undefined || requested === null) return this.ttlMs;
    return Math.min(Math.max(requested, MIN_TTL_S) * 1000, this.ttlMs);
  }

  // Active leases past their hard TTL.
  expired(now = Date.now()) {
    return this.#active().filter((lease) => now >= lease.expiresAt);
  }

  // Active leases nobody is connected to: the client disconnected and did not come back
  // within graceMs, or never connected within neverConnectedGraceMs of becoming ready.
  disconnected(
    now = Date.now(),
    graceMs = DISCONNECT_GRACE_MS,
    neverConnectedGraceMs = NEVER_CONNECTED_GRACE_MS,
  ) {
    return this.#active().filter((lease) => {
      if (lease.connections > 0) return false;
      if (!lease.everConnected)
        return now - lease.readyAt >= neverConnectedGraceMs;
      return now - lease.lastDisconnectAt >= graceMs;
    });
  }

  // Active leases whose browser process is gone.
  exited() {
    return this.#active().filter((lease) => lease.processExited);
  }

  // Everything the reaper must kill this tick, each lease once, with the first reason.
  reapable(now = Date.now()) {
    const seen = new Set();
    const result = [];
    const add = (leases, reason) => {
      for (const lease of leases) {
        if (seen.has(lease.id)) continue;
        seen.add(lease.id);
        result.push({ lease, reason });
      }
    };
    add(this.exited(), 'process_exit');
    add(this.expired(now), 'ttl');
    add(this.disconnected(now), 'disconnected');
    return result;
  }

  toHealth() {
    return { leases: this.byId.size, max: this.maxBrowsers };
  }

  #active() {
    return this.all().filter((lease) => lease.state === 'active');
  }
}
