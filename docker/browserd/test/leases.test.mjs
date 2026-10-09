import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  LeaseTable,
  DISCONNECT_GRACE_MS,
  NEVER_CONNECTED_GRACE_MS,
  UPSTREAM_PORT_OFFSET,
  MIN_TTL_S,
} from '../leases.mjs';

const T0 = 1_000_000;
const build = (overrides = {}) =>
  new LeaseTable({
    maxBrowsers: 2,
    ttlSeconds: 600,
    wsPortBase: 9301,
    ...overrides,
  });
const ready = (table, owner, now = T0) => {
  const lease = table.acquire(owner, {}, now);
  table.markReady(lease.id, now);
  return lease;
};

test('rejects invalid configuration', () => {
  assert.throws(() => build({ maxBrowsers: 0 }));
  assert.throws(() => build({ ttlSeconds: 1.5 }));
  assert.throws(() => build({ wsPortBase: undefined }));
});

test('acquire returns null when every slot is taken (cap)', () => {
  const table = build();
  assert.ok(table.acquire('a'));
  assert.ok(table.acquire('b'));
  assert.equal(table.acquire('c'), null);
  assert.deepEqual(table.toHealth(), { leases: 2, max: 2 });
});

test('assigns the lowest free slot and its ports', () => {
  const table = build({ maxBrowsers: 3 });
  const first = table.acquire('a');
  const second = table.acquire('b');
  assert.equal(first.slot, 0);
  assert.equal(first.port, 9301);
  assert.equal(first.upstreamPort, 9301 + UPSTREAM_PORT_OFFSET);
  assert.equal(second.port, 9302);

  table.beginRelease(first.id);
  table.release(first.id);
  const third = table.acquire('c');
  assert.equal(third.slot, 0);
  assert.equal(third.port, 9301);
});

test('a releasing lease keeps its slot until release()', () => {
  const table = build({ maxBrowsers: 1 });
  const lease = ready(table, 'a');
  assert.equal(table.beginRelease(lease.id), lease);
  assert.equal(
    table.beginRelease(lease.id),
    null,
    'second beginRelease is a no-op',
  );
  assert.equal(table.acquire('b'), null);

  assert.equal(table.release(lease.id), true);
  assert.equal(table.release(lease.id), false);
  assert.ok(table.acquire('b'));
});

test('TTL expiry counts from markReady', () => {
  const table = build({ ttlSeconds: 10 });
  const lease = ready(table, 'a');
  assert.equal(lease.expiresAt, T0 + 10_000);
  assert.deepEqual(table.expired(T0 + 9_999), []);
  assert.deepEqual(table.expired(T0 + 10_000), [lease]);
});

test('launching leases are never reaped by TTL or disconnect rules', () => {
  const table = build();
  table.acquire('a', {}, T0);
  assert.deepEqual(table.reapable(T0 + 10 * 60 * 60 * 1000), []);
});

test('never-connected leases get the longer grace from readiness', () => {
  const table = build();
  const lease = ready(table, 'a');
  assert.deepEqual(table.disconnected(T0 + NEVER_CONNECTED_GRACE_MS - 1), []);
  assert.deepEqual(table.disconnected(T0 + NEVER_CONNECTED_GRACE_MS), [lease]);
});

test('disconnect grace starts when the last connection drops', () => {
  const table = build();
  const lease = ready(table, 'a');
  table.markConnected(lease.id, +1, T0 + 1_000);
  assert.deepEqual(
    table.disconnected(T0 + 10 * 60 * 1000 - 1),
    [],
    'connected leases are never disconnected',
  );

  table.markConnected(lease.id, -1, T0 + 5_000);
  assert.deepEqual(
    table.disconnected(T0 + 5_000 + DISCONNECT_GRACE_MS - 1),
    [],
  );
  assert.deepEqual(table.disconnected(T0 + 5_000 + DISCONNECT_GRACE_MS), [
    lease,
  ]);

  table.markConnected(lease.id, +1, T0 + 6_000);
  assert.deepEqual(
    table.disconnected(T0 + 5_000 + DISCONNECT_GRACE_MS),
    [],
    'a reconnect cancels the grace',
  );
});

test('connection count never goes negative', () => {
  const table = build();
  const lease = ready(table, 'a');
  table.markConnected(lease.id, -1, T0);
  assert.equal(lease.connections, 0);
});

test('process exit makes a lease reapable once, with the first reason', () => {
  const table = build({ ttlSeconds: 1 });
  const lease = ready(table, 'a');
  table.markProcessExit(lease.id);
  assert.deepEqual(table.reapable(T0 + 5_000), [
    { lease, reason: 'process_exit' },
  ]);

  table.beginRelease(lease.id);
  assert.deepEqual(
    table.reapable(T0 + 5_000),
    [],
    'releasing leases are not reaped again',
  );
});

test('releaseByOwnerPrefix marks only matching active leases', () => {
  const table = build({ maxBrowsers: 4 });
  const a = ready(table, 'web-1:42:abc');
  const b = ready(table, 'web-1:42:def');
  const c = ready(table, 'web-2:7:xyz');
  const launching = table.acquire('web-1:42:ghi');

  assert.deepEqual(table.releaseByOwnerPrefix('web-1:'), [a, b]);
  assert.deepEqual(
    table.releaseByOwnerPrefix('web-1:'),
    [],
    'already releasing',
  );
  assert.deepEqual(
    table.releaseByOwnerPrefix(''),
    [],
    'empty prefix never matches everything',
  );
  assert.equal(c.state, 'active');
  assert.equal(
    launching.state,
    'launching',
    'the launching request owns its own teardown',
  );
  assert.deepEqual(
    table.toHealth(),
    { leases: 4, max: 4 },
    'slots stay held until release()',
  );
});

test('process exit of a launching lease is left to the launch path', () => {
  const table = build();
  const lease = table.acquire('a', {}, T0);
  table.markProcessExit(lease.id);
  assert.deepEqual(table.reapable(T0), []);
});

test('a lease lives the ttl it asked for, clamped to [MIN_TTL_S, ttlSeconds]', () => {
  const table = build({ maxBrowsers: 3, ttlSeconds: 1800 });
  const asked = table.acquire('a', { ttlSeconds: 1260 }, T0);
  const short = table.acquire('b', { ttlSeconds: 5 }, T0);
  const long = table.acquire('c', { ttlSeconds: 7200 }, T0);
  [asked, short, long].forEach((lease) => table.markReady(lease.id, T0));

  assert.equal(asked.expiresAt, T0 + 1260 * 1000);
  assert.equal(short.expiresAt, T0 + MIN_TTL_S * 1000);
  assert.equal(long.expiresAt, T0 + 1800 * 1000);
  assert.deepEqual(
    table.expired(T0 + 1260 * 1000).map((lease) => lease.owner),
    ['a', 'b'],
  );
});

test('a lease without ttlSeconds lives the table ttl', () => {
  const table = build({ ttlSeconds: 900 });
  const lease = ready(table, 'a');
  assert.equal(lease.expiresAt, T0 + 900 * 1000);
});
