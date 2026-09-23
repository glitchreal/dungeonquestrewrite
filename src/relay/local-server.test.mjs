import test from 'node:test';
import assert from 'node:assert/strict';
import { LocalRelay } from './local-server.mjs';

test('local relay expires clients quickly and scopes regroup to the old job', () => {
  let now = 1000;
  const relay = new LocalRelay('x'.repeat(32), () => now);
  const base = { roster: [1, 2, 3], hostId: 1, carryId: 2, userId: 1, jobId: 'old',
    placeId: 85776757589518, mode: 'Dungeon', enabled: true, ready: true, healCount: 2 };
  assert(relay.authorized(`Bearer ${'x'.repeat(32)}`));
  assert(!relay.authorized('Bearer wrong'));
  relay.sync(base);
  relay.sync({ ...base, userId: 2 });
  let result = relay.sync({ ...base, userId: 3 });
  assert.equal(result.members.length, 3);
  assert.equal(result.members.find(member => member.userId === 1).healCount, 2);
  result = relay.sync({ ...base, regroup: 'Progression' });
  assert.equal(result.command.jobId, 'old');
  now += 5001;
  result = relay.sync({ ...base, userId: 2, jobId: 'new' });
  assert.deepEqual(result.members.map(member => member.userId), [2]);
  assert.equal(result.command.jobId, 'old');
  now += 30000;
  assert.equal(relay.sync({ ...base, userId: 2, jobId: 'new' }).command, null);
});

test('phase transport and transition epochs are authoritative, idempotent, and expire', () => {
  let now = 100000;
  const relay = new LocalRelay('x'.repeat(32), () => now);
  const base = { roster: [1, 2, 3], hostId: 1, carryId: 2, userId: 1, jobId: 'run', placeId: 10,
    mode: 'Dungeon', enabled: true, ready: true, phase: 'RUNNING' };
  const transition = { version: 2, id: 'epoch-1', authorId: 1, jobId: 'run', placeId: 10,
    phase: 'REPLAYING', reason: 'Same dungeon', at: 100, expiresAt: 190 };
  let result = relay.sync({ ...base, transition, phase: 'REPLAYING' });
  assert.equal(result.members[0].phase, 'REPLAYING');
  assert.equal(result.command.id, 'epoch-1');
  now += 10000;
  result = relay.sync({ ...base, transition: { ...transition, expiresAt: 200 } });
  assert.equal(result.command.expiresAt, 190, 'Duplicate epoch cannot extend expiry');
  result = relay.sync({ ...base, userId: 3, transition: { ...transition, id: 'bad', authorId: 3 } });
  assert.equal(result.command.id, 'epoch-1');
  result = relay.sync({ ...base, userId: 2, transition: { ...transition, id: 'carry', authorId: 2, phase: 'RECOVERING' } });
  assert.equal(result.command.id, 'epoch-1', 'Carry cannot replace a live Host');
  now = 140000;
  result = relay.sync({ ...base, userId: 2, transition: { ...transition, id: 'carry', authorId: 2, phase: 'RECOVERING', at: 140, expiresAt: 230 } });
  assert.equal(result.command.id, 'carry');
  result = relay.sync({ ...base, transition });
  assert.equal(result.command.id, 'carry', 'Older decision cannot replace a newer epoch');
  now = 231000;
  assert.equal(relay.sync({ ...base, userId: 3 }).command, null);
});
