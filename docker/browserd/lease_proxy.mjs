// Public face of one lease: 0.0.0.0:<WS_PORT_BASE+slot> -> 127.0.0.1:<upstreamPort>, the Playwright
// server camoufox-js started. Raw TCP piping after the upgrade request keeps the Playwright protocol
// byte-exact; this is where ws connections are counted. Unit-tested in test/lease_proxy.test.mjs.
//
// Every socket the proxy accepts (piped OR rejected) is tracked, so closeLeaseProxy can always destroy
// it: http.Server does not see upgraded sockets (closeAllConnections skips them) and keeps half-open
// sockets alive until the peer's FIN, so one untracked socket would keep server.close() pending forever.
import http from 'node:http';
import net from 'node:net';
import crypto from 'node:crypto';

export const MAX_WS_CONNECTIONS_PER_LEASE = 1;
// A rejected upgrade gets this long to flush its status line before the socket is destroyed.
export const REJECT_FLUSH_MS = 1_000;

function safeEqual(a, b) {
  const left = crypto.createHash('sha256').update(String(a)).digest();
  const right = crypto.createHash('sha256').update(String(b)).digest();
  return crypto.timingSafeEqual(left, right);
}

function track(sockets, socket) {
  sockets.add(socket);
  socket.once('close', () => sockets.delete(socket));
}

// Writes the status line, then destroys the socket: `end()` alone half-closes it and, with the
// server's allowHalfOpen, a peer that never closes its side would hold it (and server.close) open.
function rejectUpgrade(socket, status) {
  const timer = setTimeout(() => socket.destroy(), REJECT_FLUSH_MS);
  timer.unref();
  socket.end(
    `HTTP/1.1 ${status} ${http.STATUS_CODES[status]}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`,
    () => {
      clearTimeout(timer);
      socket.destroy();
    },
  );
}

function upstreamRequestHead(req, upstreamPort) {
  const lines = [`${req.method} ${req.url} HTTP/${req.httpVersion}`];
  for (let i = 0; i < req.rawHeaders.length; i += 2) {
    const name = req.rawHeaders[i];
    const value =
      name.toLowerCase() === 'host'
        ? `127.0.0.1:${upstreamPort}`
        : req.rawHeaders[i + 1];
    lines.push(`${name}: ${value}`);
  }
  return `${lines.join('\r\n')}\r\n\r\n`;
}

// `lease` is the live LeaseTable record (state, connections, port, upstreamPort are read on every
// upgrade). `onConnection(+1 | -1)` keeps the table's connection count; `log(level, msg, fields)`.
// Resolves to { server, sockets } once listening.
export function startLeaseProxy({ lease, wsPath, onConnection, log }) {
  const sockets = new Set();
  const expectedPath = `/${wsPath}`;
  const server = http.createServer((_req, res) => {
    res.writeHead(404, { 'Content-Length': 0, Connection: 'close' });
    res.end();
  });

  server.on('upgrade', (req, socket, head) => {
    track(sockets, socket);
    socket.on('error', () => socket.destroy());
    const pathname = new URL(req.url, 'http://lease').pathname;
    if (!safeEqual(pathname, expectedPath)) return rejectUpgrade(socket, 404);
    if (lease.state !== 'active') return rejectUpgrade(socket, 410);
    if (lease.connections >= MAX_WS_CONNECTIONS_PER_LEASE)
      return rejectUpgrade(socket, 409);

    const upstream = net.connect({
      host: '127.0.0.1',
      port: lease.upstreamPort,
    });
    track(sockets, upstream);
    onConnection(+1);
    log('info', 'lease_connected', { id: lease.id });

    let closed = false;
    const close = () => {
      if (closed) return;
      closed = true;
      socket.destroy();
      upstream.destroy();
      onConnection(-1);
      log('info', 'lease_disconnected', { id: lease.id });
    };
    socket.setNoDelay(true);
    upstream.setNoDelay(true);
    upstream.once('connect', () => {
      upstream.write(upstreamRequestHead(req, lease.upstreamPort));
      if (head.length > 0) upstream.write(head);
      socket.pipe(upstream);
      upstream.pipe(socket);
    });
    for (const s of [socket, upstream]) {
      s.on('error', close);
      s.on('close', close);
    }
  });

  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(lease.port, '0.0.0.0', () => {
      server.off('error', reject);
      resolve({ server, sockets });
    });
  });
}

// Destroys every tracked socket and closes the listener. Bounded: resolves after at most `graceMs`
// even if server.close() never calls back (the listening socket is already closed by then, so the
// port is free for the slot's next lease). Resolves `true` when the close completed, `false` on timeout.
export function closeLeaseProxy(proxy, graceMs) {
  for (const socket of proxy.sockets) socket.destroy();
  const closed = new Promise((resolve) =>
    proxy.server.close(() => resolve(true)),
  );
  proxy.server.closeAllConnections();
  let timer;
  const timedOut = new Promise((resolve) => {
    timer = setTimeout(() => resolve(false), graceMs);
  });
  return Promise.race([closed, timedOut]).finally(() => clearTimeout(timer));
}
