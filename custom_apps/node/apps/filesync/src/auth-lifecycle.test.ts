import assert from 'node:assert/strict';
import test from 'node:test';
import {
  createCallbackProcessor,
  createStartupGeneration,
  isTerminalSessionError,
  shouldRestoreSessionBackup,
} from './auth-lifecycle.ts';

test('terminal invalid_grant prevents restoring a revoked browser backup', () => {
  assert.equal(isTerminalSessionError(new Error('invalid_grant: refresh token revoked')), true);
  assert.equal(shouldRestoreSessionBackup(new Error('invalid_grant')), false);
  assert.equal(shouldRestoreSessionBackup(new Error('network offline')), true);
});

test('duplicate callback deliveries share one in-flight login and preserve success', async () => {
  let finishCalls = 0;
  let resolveLogin!: (value: string) => void;
  const processor = createCallbackProcessor(async () => {
    finishCalls += 1;
    return await new Promise<string>((resolve) => { resolveLogin = resolve; });
  });
  const first = processor('filesync://oauth/callback?code=x&state=y');
  const duplicate = processor('filesync://oauth/callback?code=x&state=y');
  assert.equal(finishCalls, 1);
  resolveLogin('alice');
  assert.equal(await first, 'alice');
  assert.equal(await duplicate, 'alice');
  assert.equal(finishCalls, 1);
});

test('failed callback may be retried and a replacement callback is not coalesced', async () => {
  let calls = 0;
  const processor = createCallbackProcessor(async () => {
    calls += 1;
    if (calls === 1) throw new Error('expired');
    return 'bob';
  });
  await assert.rejects(processor('filesync://oauth/callback?first'));
  assert.equal(await processor('filesync://oauth/callback?first'), 'bob');
  assert.equal(await processor('filesync://oauth/callback?replacement'), 'bob');
  assert.equal(calls, 3);
});

test('startup result commits only while its generation remains current', () => {
  const startup = createStartupGeneration();
  const pending = startup.begin();
  assert.equal(startup.isCurrent(pending), true);
  startup.invalidate();
  assert.equal(startup.isCurrent(pending), false);
  assert.equal(startup.isCurrent(startup.begin()), true);
});
