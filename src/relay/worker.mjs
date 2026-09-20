const json = (data, status = 200) => Response.json(data, { status, headers: { 'Cache-Control': 'no-store' } });
const integer = value => Number.isSafeInteger(value) && value > 0;

export function validate(data) {
  if (!data || !Array.isArray(data.roster) || data.roster.length < 2 || data.roster.length > 20
      || !data.roster.every(integer) || new Set(data.roster).size !== data.roster.length
      || !integer(data.userId) || !data.roster.includes(data.userId)
      || !data.roster.includes(data.hostId) || !data.roster.includes(data.carryId) || data.hostId === data.carryId
      || typeof data.jobId !== 'string' || !/^[\w-]{1,100}$/.test(data.jobId)
      || !integer(data.placeId) || !['Lobby', 'Dungeon'].includes(data.mode)
      || typeof data.ready !== 'boolean' || typeof data.enabled !== 'boolean'
      || (data.healCount !== undefined && (!Number.isInteger(data.healCount) || data.healCount < 0 || data.healCount > 100))
      || (data.regroup !== undefined && (typeof data.regroup !== 'string' || data.regroup.length > 160))) return false;
  return true;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/health' && request.method === 'GET') return json({ ok: true, protocol: 1 });
    if (url.pathname !== '/sync' || request.method !== 'POST') return json({ error: 'Not found' }, 404);
    if (!env.RELAY_TOKEN || env.RELAY_TOKEN.length < 32) return json({ error: 'Relay is not configured' }, 503);
    // Hash both strings to fixed lengths before timing-safe comparison.
    const hash = text => crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
    const [actual, expected] = await Promise.all([
      hash(request.headers.get('Authorization') || ''), hash(`Bearer ${env.RELAY_TOKEN}`),
    ]);
    if (!crypto.subtle.timingSafeEqual(actual, expected)) return json({ error: 'Unauthorized' }, 401);
    if (Number(request.headers.get('Content-Length')) > 8192) return json({ error: 'Too large' }, 413);
    let data;
    try {
      const body = await request.text();
      if (body.length > 8192) return json({ error: 'Too large' }, 413);
      data = JSON.parse(body);
    } catch { return json({ error: 'Invalid JSON' }, 400); }
    if (!validate(data)) return json({ error: 'Invalid heartbeat' }, 400);
    // Canonical IDs keep clients with reordered alt lists in the same room.
    const room = `${data.hostId}:${data.carryId}:${[...data.roster].sort((a, b) => a - b).join(',')}`;
    return env.PARTIES.get(env.PARTIES.idFromName(room)).fetch(new Request('https://party/sync', {
      method: 'POST', body: JSON.stringify(data),
    }));
  },
};

export class Party {
  constructor(ctx) {
    this.ctx = ctx;
    this.members = new Map();
    this.command = null;
    ctx.blockConcurrencyWhile(async () => { this.command = await ctx.storage.get('command') || null; });
  }

  async fetch(request) {
    const data = await request.json();
    const now = Date.now();
    const previous = this.members.get(data.userId);
    if (previous && previous.jobId === data.jobId && now - previous.at < 2000) return json({ error: 'Slow down' }, 429);
    for (const [id, member] of this.members) if (now - member.at > 35000) this.members.delete(id);
    this.members.set(data.userId, {
      userId: data.userId, jobId: data.jobId, placeId: data.placeId, mode: data.mode,
      enabled: data.enabled, ready: data.ready, at: now,
      healCount: data.healCount,
    });
    // Only the configured host announces a regroup. It applies solely to the old
    // dungeon job, so a delayed message cannot eject a newly assembled party.
    if (data.regroup && data.userId === data.hostId && data.mode === 'Dungeon' && data.enabled) {
      this.command = { jobId: data.jobId, reason: data.regroup, expiresAt: now + 180000 };
      await this.ctx.storage.put('command', this.command);
    }
    const command = this.command && this.command.expiresAt > now ? this.command : null;
    return json({ protocol: 1, members: [...this.members.values()].map(({ at, ...member }) => ({
      ...member, age: (now - at) / 1000,
    })), command: command ? { jobId: command.jobId, reason: command.reason } : null });
  }
}
