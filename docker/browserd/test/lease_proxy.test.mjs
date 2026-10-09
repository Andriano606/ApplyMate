import { test } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { once } from 'node:events';
import { startLeaseProxy, closeLeaseProxy } from '../lease_proxy.mjs';

const WS_PATH = 'a'.repeat(64);
const clients = [];
test.afterEach(() => {
  for (const socket of clients.splice(0)) socket.destroy();
});
const GRACE_MS = 2_000;
const silent = () => {};

// A stand-in Playwright upstream that accepts and holds connections.
async function startUpstream() {
  const sockets = new Set();
  const server = net.createServer((socket) => {
    sockets.add(socket);
    socket.on('error', () => {});
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return {
    port: server.address().port,
    close: () => {
      for (const socket of sockets) socket.destroy();
      server.close();
    },
  };
}

async function startProxy(upstreamPort, state = 'active') {
  const lease = {
    id: 'lease-1',
    state,
    connections: 0,
    port: 0,
    upstreamPort,
  };
  const proxy = await startLeaseProxy({
    lease,
    wsPath: WS_PATH,
    onConnection: (delta) => {
      lease.connections += delta;
    },
    log: silent,
  });
  return { lease, proxy, port: proxy.server.address().port };
}

// A client that never closes its side on its own (allowHalfOpen), like a stuck peer.
async function upgrade(port, path) {
  const socket = net.connect({ port, host: '127.0.0.1', allowHalfOpen: true });
  socket.on('error', () => {});
  clients.push(socket);
  await once(socket, 'connect');
  socket.write(
    `GET ${path} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n`,
  );
  const chunks = [];
  socket.on('data', (chunk) => chunks.push(chunk));
  return { socket, response: () => Buffer.concat(chunks).toString() };
}

const waitUntil = async (predicate, ms = 2_000) => {
  const started = Date.now();
  while (!predicate()) {
    if (Date.now() - started > ms) throw new Error('condition not met');
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
};

test(
  'a rejected upgrade is destroyed, so teardown completes although the peer never closes',
  { timeout: 10_000 },
  async () => {
    const upstream = await startUpstream();
    const { lease, proxy, port } = await startProxy(upstream.port);
    try {
      const first = await upgrade(port, `/${WS_PATH}`);
      await waitUntil(() => lease.connections === 1);

      const second = await upgrade(port, `/${WS_PATH}`);
      const wrongPath = await upgrade(port, '/nope');
      await Promise.all([
        once(second.socket, 'end'),
        once(wrongPath.socket, 'end'),
      ]);
      assert.match(second.response(), /^HTTP\/1\.1 409 /);
      assert.match(wrongPath.response(), /^HTTP\/1\.1 404 /);
      assert.equal(lease.connections, 1);

      const started = Date.now();
      assert.equal(await closeLeaseProxy(proxy, GRACE_MS), true);
      assert.ok(Date.now() - started < GRACE_MS);
      await once(first.socket, 'end');
      assert.equal(lease.connections, 0);
    } finally {
      upstream.close();
    }
  },
);

test(
  'a lease that is no longer active answers 410 and is closed',
  { timeout: 10_000 },
  async () => {
    const upstream = await startUpstream();
    const { proxy, port } = await startProxy(upstream.port, 'releasing');
    try {
      const client = await upgrade(port, `/${WS_PATH}`);
      await once(client.socket, 'end');
      assert.match(client.response(), /^HTTP\/1\.1 410 /);
      assert.equal(await closeLeaseProxy(proxy, GRACE_MS), true);
    } finally {
      upstream.close();
    }
  },
);

test('closeLeaseProxy is bounded even when server.close never calls back', async () => {
  const stuck = {
    server: { close: () => {}, closeAllConnections: () => {} },
    sockets: new Set(),
  };
  const started = Date.now();
  assert.equal(await closeLeaseProxy(stuck, 100), false);
  assert.ok(Date.now() - started < 1_000);
});
