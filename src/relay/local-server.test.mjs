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
