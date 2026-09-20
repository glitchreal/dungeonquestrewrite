import http from 'node:http';
import fs from 'node:fs';
import crypto from 'node:crypto';

export class LocalRelay {
  constructor(token, now = Date.now) {
    if (typeof token !== 'string' || token.length < 32) throw new Error('DQ_RELAY_TOKEN must be at least 32 characters');
    this.token = token;
    this.now = now;
    this.rooms = new Map();
  }

  authorized(header = '') {
    const actual = crypto.createHash('sha256').update(header).digest();
    const expected = crypto.createHash('sha256').update(`Bearer ${this.token}`).digest();
    return crypto.timingSafeEqual(actual, expected);
  }

  sync(data) {
    const now = this.now();
    const roomId = `${data.hostId}:${data.carryId}:${[...data.roster].sort((a, b) => a - b).join(',')}`;
    const room = this.rooms.get(roomId) || { members: new Map(), command: null };
    this.rooms.set(roomId, room);
    for (const [id, member] of room.members) if (now - member.at > 5000) room.members.delete(id);
    room.members.set(data.userId, {
      userId: data.userId, jobId: data.jobId, placeId: data.placeId, mode: data.mode,
      enabled: data.enabled, ready: data.ready, at: now,
      healCount: data.healCount,
    });
    if (data.regroup && data.userId === data.hostId && data.mode === 'Dungeon' && data.enabled) {
      room.command = { jobId: data.jobId, reason: data.regroup, expiresAt: now + 30000 };
    }
    if (room.command && room.command.expiresAt <= now) room.command = null;
    return { protocol: 1, members: [...room.members.values()].map(({ at, ...member }) => ({
      ...member, age: (now - at) / 1000,
    })), command: room.command && { jobId: room.command.jobId, reason: room.command.reason } };
  }
}

function readToken() {
  if (process.env.DQ_RELAY_TOKEN) return process.env.DQ_RELAY_TOKEN;
  try {
    const line = fs.readFileSync(new URL('.dev.vars', import.meta.url), 'utf8')
      .split(/\r?\n/).find(value => value.startsWith('RELAY_TOKEN='));
    return line?.slice('RELAY_TOKEN='.length).trim();
  } catch { return undefined; }
}

export function createServer(relay) {
  return http.createServer((request, response) => {
    response.setHeader('Content-Type', 'application/json');
    response.setHeader('Cache-Control', 'no-store');
    if (request.method === 'GET' && request.url === '/health') return response.end(JSON.stringify({ ok: true, protocol: 1 }));
    if (request.method !== 'POST' || request.url !== '/sync') {
      response.statusCode = 404;
      return response.end(JSON.stringify({ error: 'Not found' }));
    }
    if (!relay.authorized(request.headers.authorization)) {
      response.statusCode = 401;
      return response.end(JSON.stringify({ error: 'Unauthorized' }));
    }
    let body = '';
    request.on('data', chunk => {
      body += chunk;
      if (body.length > 8192) request.destroy();
    });
    request.on('end', async () => {
      try {
        const { validate } = await import('./worker.mjs');
        const data = JSON.parse(body);
        if (!validate(data)) {
          response.statusCode = 400;
          return response.end(JSON.stringify({ error: 'Invalid heartbeat' }));
        }
        response.end(JSON.stringify(relay.sync(data)));
      } catch {
        response.statusCode = 400;
        response.end(JSON.stringify({ error: 'Invalid JSON' }));
      }
    });
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.env.DQ_RELAY_PORT || 8788);
  const server = createServer(new LocalRelay(readToken()));
  server.listen(port, '0.0.0.0', () => {
    console.log(`Dungeon Quest local relay ready on http://127.0.0.1:${port}`);
    console.log(`Android emulator host URL is commonly http://10.0.2.2:${port}`);
  });
}
