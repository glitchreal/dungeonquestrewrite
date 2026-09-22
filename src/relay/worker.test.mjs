import test from 'node:test';
import assert from 'node:assert/strict';
import { Party, validate } from './worker.mjs';

test('heartbeats, room inputs, host regroup scope, expiry, and restart', async () => {
  const saved = new Map();
  let loaded;
  const ctx = {
    storage: { get: async key => saved.get(key), put: async (key, value) => saved.set(key, value) },
    blockConcurrencyWhile: fn => { loaded = fn(); },
  };
  let room = new Party(ctx); await loaded;
  let now = 100000;
  const originalNow = Date.now; Date.now = () => now;
  const base = { roster: [1, 2, 3], userId: 1, hostId: 1, carryId: 2, jobId: 'old-job',
    placeId: 85776757589518, mode: 'Dungeon', enabled: true, ready: true, healCount: 2 };
  const post = async overrides => {
    const response = await room.fetch(new Request('https://test/sync', { method: 'POST', body: JSON.stringify({ ...base, ...overrides }) }));
    return { status: response.status, data: await response.json() };
  };
  try {
    assert(validate(base));
    assert(!validate({ ...base, roster: [1, 1, 3] }));
    assert(!validate({ ...base, userId: 4 }));
    assert(!validate({ ...base, ready: 'true' }));
    await post({}); await post({ userId: 2 });
    let reply = await post({ userId: 3, ready: false });
    assert.equal(reply.data.members.length, 3);
    assert.equal(reply.data.members.find(m => m.userId === 1).healCount, 2);
    assert.equal(reply.data.members.find(m => m.userId === 3).ready, false);
    assert.equal((await post({})).status, 429);
    now += 10000;
    reply = await post({ userId: 2, regroup: 'Must not be accepted' });
    assert.equal(reply.data.command, null);
    reply = await post({ regroup: 'Progression' });
    assert.equal(reply.data.command.jobId, 'old-job');
    reply = await post({ jobId: 'new-job' });
    assert.equal(reply.data.command.jobId, 'old-job', 'New dungeon must not be targeted by old command');
    room = new Party(ctx); await loaded;
    reply = await post({ userId: 2 });
    assert.equal(reply.data.command.reason, 'Progression', 'Command survives host teleport and relay eviction');
    now += 36000;
    reply = await post({ userId: 3 });
    assert.deepEqual(reply.data.members.map(m => m.userId), [3], 'Expired heartbeats cannot report ready');
    now += 180000;
    assert.equal((await post({})).data.command, null);
  } finally { Date.now = originalNow; }
});
