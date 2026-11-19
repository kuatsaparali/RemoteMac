import { randomBytes, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { WebSocket, WebSocketServer } from 'ws';

const hostKey = process.env.MACREMOTE_HOST_KEY ?? randomBytes(32).toString('base64url');
const port = Number(process.env.PORT ?? 8787);
const host = process.env.BIND_HOST ?? '127.0.0.1';
const tokenPattern = /^[A-Za-z0-9_-]{43}$/;
const roomPattern = /^[A-Za-z0-9_-]{22}$/;
const rooms = new Map();
const assets = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/locale.js', ['locale.js', 'text/javascript; charset=utf-8']],
  ['/audio.js', ['audio.js', 'text/javascript; charset=utf-8']],
  ['/chat.js', ['chat.js', 'text/javascript; charset=utf-8']],
  ['/client.js', ['client.js', 'text/javascript; charset=utf-8']],
  ['/style.css', ['style.css', 'text/css; charset=utf-8']],
].map(([route, [file, type]]) => [
  route, { type, bytes: readFileSync(new URL('public/' + file, import.meta.url)) },
]));

if (!tokenPattern.test(hostKey)) {
  throw new Error('MACREMOTE_HOST_KEY must be a 32-byte base64url key without padding');
}

export const server = createServer((request, response) => {
  const asset = assets.get(request.url?.split('?')[0]);
  response.setHeader('Cache-Control', 'no-store');
  response.setHeader('Referrer-Policy', 'no-referrer');
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('Content-Security-Policy',
    "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'");
  if (!asset || !['GET', 'HEAD'].includes(request.method)) {
    response.writeHead(404).end();
    return;
  }
  response.writeHead(200, { 'Content-Type': asset.type });
  response.end(request.method === 'HEAD' ? undefined : asset.bytes);
});

const sockets = new WebSocketServer({ noServer: true, maxPayload: 768 * 1024, perMessageDeflate: false });
server.on('upgrade', (request, socket, head) => {
  if (request.url !== '/ws' || sockets.clients.size >= 64) {
    socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
    return;
  }
  sockets.handleUpgrade(request, socket, head, connection => sockets.emit('connection', connection));
});

function send(socket, type, fields) {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type, ...fields }));
}

function matches(expected, actual) {
  return typeof actual === 'string' && tokenPattern.test(actual)
    && timingSafeEqual(Buffer.from(expected), Buffer.from(actual));
}

function endRoom(room, reason) {
  if (rooms.get(room.id) !== room) return;
  rooms.delete(room.id);
  clearTimeout(room.approvalTimeout);
  for (const peer of [room.host, room.viewer]) {
    send(peer, reason);
    peer?.close(1000);
  }
}

sockets.on('connection', socket => {
  let room;
  let role;
  let alive = true;
  const authTimeout = setTimeout(() => socket.close(1008, 'authorization timeout'), 8000);
  const heartbeat = setInterval(() => {
    if (!alive) {
      socket.terminate();
      return;
    }
    alive = false;
    if (socket.readyState === WebSocket.OPEN) socket.ping();
  }, 8000);
  socket.on('pong', () => { alive = true; });
  socket.on('error', () => socket.terminate());
  socket.on('close', () => {
    clearTimeout(authTimeout);
    clearInterval(heartbeat);
    if (room) endRoom(room, 'ended');
  });

  socket.on('message', (data, binary) => {
    if (role && rooms.get(room.id) !== room) return;
    if (binary) {
      if (!room?.active || data.length < 29) return;
      const target = role === 'host' ? room.viewer : room.host;
      if (target?.readyState !== WebSocket.OPEN) return;
      // Audio is independently encrypted and can skip stale chunks under congestion.
      if (role === 'host' && data.readUInt32BE(0) === 3 && target.bufferedAmount > 192 * 1024) return;
      // Paced video has dependent H.264 frames. The host bounds this stream with encrypted display ACKs.
      if (role === 'host' && !room.paced && target.bufferedAmount > 384 * 1024) return;
      if (role === 'host' && room.paced && target.bufferedAmount > 2 * 768 * 1024) {
        endRoom(room, 'ended');
        return;
      }
      if (role === 'viewer' && (data.length > 2048 || target.bufferedAmount > 64 * 1024)) {
        endRoom(room, 'ended');
        return;
      }
      target.send(data, { binary: true });
      return;
    }

    if (data.length > 512) {
      socket.close(1008, 'invalid message');
      return;
    }
    let message;
    try { message = JSON.parse(data.toString()); } catch { socket.close(1008); return; }
    if (!message || typeof message !== 'object') { socket.close(1008); return; }
    if (role) {
      if (message.type === 'end') endRoom(room, 'ended');
      if (role !== 'host' || !room.viewer || room.active) return;
      if (message.type === 'reject') endRoom(room, 'rejected');
      if (message.type === 'approve') {
        clearTimeout(room.approvalTimeout);
        room.active = true;
        send(room.viewer, 'active');
      }
      return;
    }

    if (message.type === 'host' && matches(hostKey, message.key)
      && typeof message.room === 'string' && roomPattern.test(message.room)
      && typeof message.ticket === 'string' && tokenPattern.test(message.ticket)
      && !rooms.has(message.room) && rooms.size < 8) {
      clearTimeout(authTimeout);
      room = { id: message.room, ticket: message.ticket, host: socket, active: false, supportsPacing: message.paced === '1' };
      role = 'host';
      rooms.set(room.id, room);
      send(socket, 'ready');
      return;
    }
    const requested = message.type === 'join' && rooms.get(message.room);
    if (requested && !requested.viewer && matches(requested.ticket, message.ticket)) {
      clearTimeout(authTimeout);
      room = requested;
      role = 'viewer';
      room.viewer = socket;
      room.paced = room.supportsPacing && message.paced === true;
      room.approvalTimeout = setTimeout(() => endRoom(room, 'expired'), 60_000);
      send(socket, 'waiting');
      send(room.host, 'request', message.mobile === true ? { mobile: '1' } : undefined);
      return;
    }
    send(socket, 'denied');
    socket.close(1008);
  });
});

server.listen(port, host, () => {
  console.log('MacRemote relay: http://' + host + ':' + server.address().port);
  if (!process.env.MACREMOTE_HOST_KEY) console.log('Ключ сервера для приложения MacRemote: ' + hostKey);
});
