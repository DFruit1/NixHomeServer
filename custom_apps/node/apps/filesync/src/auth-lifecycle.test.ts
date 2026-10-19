import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import {
  createCallbackProcessor,
  createCallbackOwnership,
  createStartupGeneration,
  isTerminalSessionError,
  shouldRestoreSessionBackup,
} from './auth-lifecycle.ts';

test('terminal invalid_grant prevents restoring a revoked browser backup', () => {
  assert.equal(isTerminalSessionError(new Error('invalid_grant: refresh token revoked')), true);
  assert.equal(isTerminalSessionError('invalid_grant: refresh token revoked'), true);
  assert.equal(shouldRestoreSessionBackup('session expired or was revoked'), false);
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

test('main callback handler preserves a valid transaction after rejected state and retries failed native completion', async () => {
  const source = readFileSync(new URL('./main.ts', import.meta.url), 'utf8');
  const start = source.indexOf('async function finishCallbackOnce(');
  const end = source.indexOf('\nconst finishCallback =', start);
  assert.ok(start >= 0 && end > start, 'production callback handler is present');
  const handlerSource = source.slice(start, end)
    .replace('async function finishCallbackOnce(url: string): Promise<string | undefined> {', 'async function finishCallbackOnce(url) {')
    .replaceAll('invoke<string>(', 'invoke(')
    .replaceAll('invoke<boolean>(', 'invoke(')
    .replace('let generation: number | undefined;', 'let generation;');
  const generation = createStartupGeneration();
  const state: Record<string, unknown> = { user: undefined, offline: false, error: '', notice: '', settingsAuthorized: false };
  let resolveValid!: (user: string) => void;
  let validCalls = 0;
  let retryCalls = 0;
  const invoke = async (command: string, args?: { callbackUrl?: string }) => {
    if (command === 'finish_login' && args?.callbackUrl?.includes('valid')) {
      validCalls += 1;
      return await new Promise<string>((resolve) => { resolveValid = resolve; });
    }
    if (command === 'finish_login' && args?.callbackUrl?.includes('retry')) {
      retryCalls += 1;
      if (retryCalls === 1) throw 'secure storage unavailable';
      return 'bob';
    }
    if (command === 'finish_login') throw 'OAuth callback state mismatch';
    if (command === 'settings_authorized') return true;
    if (command === 'session_backup') return 'fresh-backup';
    if (command === 'server_presets') return [];
    if (command === 'update_background_syncs') return undefined;
    throw new Error(`unexpected invoke: ${command}`);
  };
  const handler = new Function('startupGeneration', 'callbackOwnership', 'invoke', 'state', 'cacheSignedInUser', 'saveSessionBackup', 'loadPresets', 'applySpacePrefsToPairs', 'persistPairs', 'render', 'refreshEstimates', `${handlerSource}; return finishCallbackOnce;`)(
    generation, createCallbackOwnership(), invoke, state,
    (user: string) => { state.user = user; }, async () => undefined, async () => undefined,
    () => undefined, async () => undefined, () => undefined, async () => undefined,
  ) as (url: string) => Promise<string | undefined>;
  const processCallback = createCallbackProcessor(handler);
  const valid = processCallback('filesync://oauth/callback?valid');
  const duplicate = processCallback('filesync://oauth/callback?valid');
  assert.equal(validCalls, 1);
  await assert.rejects(processCallback('filesync://oauth/callback?wrong-state'), /OAuth callback state mismatch/);
  assert.equal(generation.current(), 0, 'rejected callback must not claim a transaction generation');
  resolveValid('alice');
  assert.equal(await valid, undefined);
  assert.equal(await duplicate, undefined);
  assert.equal(state.user, 'alice');
  await assert.rejects(processCallback('filesync://oauth/callback?retry'), /secure storage unavailable/);
  assert.equal(await processCallback('filesync://oauth/callback?retry'), undefined);
  assert.equal(state.user, 'bob');
  assert.equal(retryCalls, 2);
});

test('main callback is consumed once when ancillary preset loading fails after native login', async () => {
  const source = readFileSync(new URL('./main.ts', import.meta.url), 'utf8');
  const start = source.indexOf('async function finishCallbackOnce(');
  const end = source.indexOf('\nconst finishCallback =', start);
  assert.ok(start >= 0 && end > start, 'production callback handler is present');
  const handlerSource = source.slice(start, end)
    .replace('async function finishCallbackOnce(url: string): Promise<string | undefined> {', 'async function finishCallbackOnce(url) {')
    .replaceAll('invoke<string>(', 'invoke(')
    .replaceAll('invoke<boolean>(', 'invoke(')
    .replace('let generation: number | undefined;', 'let generation;');
  const generation = createStartupGeneration();
  const state: Record<string, unknown> = { user: undefined, offline: false, error: '', notice: '' };
  let finishCalls = 0;
  const invoke = async (command: string) => {
    if (command === 'finish_login') { finishCalls += 1; return 'alice'; }
    if (command === 'settings_authorized') return true;
    if (command === 'session_backup') return null;
    if (command === 'server_presets') throw new Error('presets temporarily unavailable');
    if (command === 'update_background_syncs') return undefined;
    throw new Error(`unexpected invoke: ${command}`);
  };
  const handler = new Function('startupGeneration', 'callbackOwnership', 'invoke', 'state', 'cacheSignedInUser', 'saveSessionBackup', 'loadPresets', 'applySpacePrefsToPairs', 'persistPairs', 'render', 'refreshEstimates', `${handlerSource}; return finishCallbackOnce;`)(
    generation, createCallbackOwnership(), invoke, state, (user: string) => { state.user = user; }, async () => undefined,
    async () => { throw new Error('presets temporarily unavailable'); }, () => undefined, async () => undefined, () => undefined, async () => undefined,
  ) as (url: string) => Promise<string | undefined>;
  const processor = createCallbackProcessor(handler);
  const callbackUrl = 'filesync://oauth/callback?already-consumed';
  assert.equal(await processor(callbackUrl), undefined);
  assert.equal(await processor(callbackUrl), undefined);
  assert.equal(finishCalls, 1);
  assert.equal(state.user, 'alice');
  assert.match(String(state.error), /presets temporarily unavailable/);
});

test('main offline startup does not replace a newer login after deferred session lookup', async () => {
  const source = readFileSync(new URL('./main.ts', import.meta.url), 'utf8');
  const start = source.indexOf('async function start(): Promise<void> {');
  const end = source.indexOf('\nasync function renderServerBrowser', start);
  assert.ok(start >= 0 && end > start, 'production startup handler is present');
  const startSource = source.slice(start, end)
    .replace('async function start(): Promise<void> {', 'async function start() {')
    .replace(/invoke<[^>]+>\(/g, 'invoke(')
    .replace('let startupError: unknown;', 'let startupError;');
  const startupGeneration = createStartupGeneration();
  const state: Record<string, unknown> = { user: undefined, offline: false, error: '', notice: '', pairs: [] };
  const storage = new Map([['nixhomeserver.filesync.user.v1', 'cached-user']]);
  let sessionLookupStarted!: () => void;
  const sessionLookupStartedPromise = new Promise<void>((resolve) => { sessionLookupStarted = resolve; });
  let resolveSessionLookup!: (value: boolean) => void;
  const hasStoredSession = () => {
    sessionLookupStarted();
    return new Promise<boolean>((resolve) => { resolveSessionLookup = resolve; });
  };
  const invoke = async (command: string) => {
    if (command === 'current_user') throw 'sync server offline';
    if (command === 'background_sync_status') return null;
    if (command === 'settings_authorized') return true;
    if (command === 'ensure_notifications') return true;
    throw new Error(`unexpected invoke: ${command}`);
  };
  const startApp = new Function('invoke', 'onOpenUrl', 'startupGeneration', 'state', 'cacheSignedInUser', 'saveSessionBackup', 'restoreSessionBackup', 'shouldRestoreSessionBackup', 'isTerminalSessionError', 'localStorage', 'USER_KEY', 'hasStoredSession', 'readBackgroundStatus', 'applySpacePrefsToPairs', 'persistPairs', 'loadPresets', 'getCurrent', 'dispatchCallback', 'window', 'refreshProgress', 'render', 'refreshEstimates', `${startSource}; return start;`)(
    invoke, async () => undefined, startupGeneration, state, (user: string) => { state.user = user; }, async () => undefined, async () => false,
    () => true, () => false, { getItem: (key: string) => storage.get(key) ?? null },
    'nixhomeserver.filesync.user.v1', hasStoredSession, () => undefined, () => undefined,
    async () => undefined, async () => undefined, async () => [], () => undefined,
    { setInterval: () => 0 }, async () => undefined, () => undefined, async () => undefined,
  ) as () => Promise<void>;
  const pendingStart = startApp();
  await sessionLookupStartedPromise;
  startupGeneration.begin();
  state.user = 'new-user';
  resolveSessionLookup(true);
  await pendingStart;
  assert.equal(state.user, 'new-user');
  assert.equal(state.offline, false);
});

test('actual callback survives listener-registration delivery and initial-link replay', async () => {
  const source = readFileSync(new URL('./main.ts', import.meta.url), 'utf8');
  const start = source.indexOf('async function start(): Promise<void> {');
  const end = source.indexOf(String.fromCharCode(10) + 'async function renderServerBrowser', start);
  const callbackStart = source.indexOf('async function finishCallbackOnce(');
  const callbackEnd = source.indexOf(String.fromCharCode(10) + 'const finishCallback =', callbackStart);
  assert.ok(start >= 0 && end > start && callbackStart >= 0 && callbackEnd > callbackStart, 'production startup and callback handlers are present');
  const startSource = source.slice(start, end)
    .replace('async function start(): Promise<void> {', 'async function start() {')
    .replace(/invoke<[^>]+>\(/g, 'invoke(')
    .replace('let startupError: unknown;', 'let startupError;');
  const callbackSource = source.slice(callbackStart, callbackEnd)
    .replace('async function finishCallbackOnce(url: string): Promise<string | undefined> {', 'async function finishCallbackOnce(url) {')
    .replaceAll('invoke<string>(', 'invoke(')
    .replaceAll('invoke<boolean>(', 'invoke(')
    .replace('let generation: number | undefined;', 'let generation;');
  const startupGeneration = createStartupGeneration();
  const callbackOwnership = createCallbackOwnership();
  const state: Record<string, unknown> = { user: undefined, offline: false, error: '', notice: '', pairs: [] };
  const callbackUrl = 'filesync://oauth/callback?startup';
  const delivered: string[] = [];
  const callbackOperations: Promise<unknown>[] = [];
  let finishCalls = 0;
  const invoke = async (command: string) => {
    if (command === 'finish_login') { finishCalls += 1; return 'new-user'; }
    if (command === 'current_user') return 'cached-user';
    if (command === 'background_sync_status') return null;
    if (command === 'settings_authorized') return true;
    if (command === 'session_backup') return null;
    if (command === 'server_presets') return [];
    if (command === 'update_background_syncs') return undefined;
    if (command === 'ensure_notifications') return true;
    throw new Error(`unexpected invoke: ${command}`);
  };
  const cacheSignedInUser = (user: string) => { state.user = user; };
  const callbackHandler = new Function('startupGeneration', 'callbackOwnership', 'invoke', 'state', 'cacheSignedInUser', 'saveSessionBackup', 'loadPresets', 'applySpacePrefsToPairs', 'persistPairs', 'render', 'refreshEstimates', `${callbackSource}; return finishCallbackOnce;`)(
    startupGeneration, callbackOwnership, invoke, state, cacheSignedInUser, async () => undefined,
    async () => undefined, () => undefined, async () => undefined, () => undefined, async () => undefined,
  ) as (url: string) => Promise<string | undefined>;
  const processCallback = createCallbackProcessor(callbackHandler);
  const startApp = new Function('invoke', 'onOpenUrl', 'startupGeneration', 'state', 'cacheSignedInUser', 'saveSessionBackup', 'restoreSessionBackup', 'shouldRestoreSessionBackup', 'isTerminalSessionError', 'localStorage', 'USER_KEY', 'hasStoredSession', 'readBackgroundStatus', 'applySpacePrefsToPairs', 'persistPairs', 'loadPresets', 'getCurrent', 'dispatchCallback', 'window', 'refreshProgress', 'render', 'refreshEstimates', `${startSource}; return start;`)(
    invoke, async (listener: (links: string[]) => void) => { listener([callbackUrl]); }, startupGeneration, state,
    cacheSignedInUser, async () => undefined, async () => false, () => true, () => false,
    { getItem: () => null }, 'nixhomeserver.filesync.user.v1', async () => false,
    () => undefined, () => undefined, async () => undefined, async () => undefined,
    async () => [callbackUrl], (url: string) => {
      delivered.push(url);
      callbackOperations.push(processCallback(url));
    },
    { setInterval: () => 0 }, async () => undefined, () => undefined, async () => undefined,
  ) as () => Promise<void>;
  await startApp();
  await Promise.all(callbackOperations);
  assert.equal(state.user, 'new-user');
  assert.equal(finishCalls, 1, 'the replay coalesces with the registration-delivered callback');
  assert.deepEqual(delivered, [callbackUrl, callbackUrl]);
});


test('main callback completion cannot replace a newer login transaction', async () => {
  const source = readFileSync(new URL('./main.ts', import.meta.url), 'utf8');
  const start = source.indexOf('async function finishCallbackOnce(');
  const end = source.indexOf('\nconst finishCallback =', start);
  assert.ok(start >= 0 && end > start, 'production callback handler is present');
  const handlerSource = source.slice(start, end)
    .replace('async function finishCallbackOnce(url: string): Promise<string | undefined> {', 'async function finishCallbackOnce(url) {')
    .replaceAll('invoke<string>(', 'invoke(')
    .replaceAll('invoke<boolean>(', 'invoke(')
    .replace('let generation: number | undefined;', 'let generation;');
  const generation = createStartupGeneration();
  let resolveOld!: (user: string) => void;
  const state: Record<string, unknown> = { user: undefined, offline: false, error: '', notice: '' };
  const invoke = async (command: string, args?: { callbackUrl?: string }) => {
    if (command === 'finish_login') return await new Promise<string>((resolve) => { resolveOld = resolve; });
    if (command === 'settings_authorized') return true;
    if (command === 'session_backup') return null;
    if (command === 'server_presets') return [];
    if (command === 'update_background_syncs') return undefined;
    throw new Error(`unexpected invoke: ${command} ${args?.callbackUrl ?? ''}`);
  };
  const handler = new Function('startupGeneration', 'callbackOwnership', 'invoke', 'state', 'cacheSignedInUser', 'saveSessionBackup', 'loadPresets', 'applySpacePrefsToPairs', 'persistPairs', 'render', 'refreshEstimates', `${handlerSource}; return finishCallbackOnce;`)(
    generation, createCallbackOwnership(), invoke, state, (user: string) => { state.user = user; }, async () => undefined,
    async () => undefined, () => undefined, async () => undefined, () => undefined, async () => undefined,
  ) as (url: string) => Promise<string | undefined>;
  const oldCompletion = handler('filesync://oauth/callback?old');
  await Promise.resolve();
  const replacement = generation.begin();
  state.user = 'new-user';
  resolveOld('old-user');
  await oldCompletion;
  assert.equal(generation.current(), replacement);
  assert.equal(state.user, 'new-user');
});

test('main restore handler does not commit a deferred prior account after a newer login', async () => {
  const source = readFileSync(new URL('./main.ts', import.meta.url), 'utf8');
  const start = source.indexOf('async function restoreSessionBackup(');
  const end = source.indexOf('\nconst startupGeneration', start);
  assert.ok(start >= 0 && end > start, 'production restore handler is present');
  const restoreSource = source.slice(start, end)
    .replace('async function restoreSessionBackup(generation: number): Promise<boolean> {', 'async function restoreSessionBackup(generation) {')
    .replaceAll('invoke<void>(', 'invoke(')
    .replaceAll('invoke<string | null>(', 'invoke(');
  const startup = createStartupGeneration();
  const oldGeneration = startup.begin();
  const storage = new Map([
    ['nixhomeserver.filesync.session-backup.v1', 'old-backup'],
    ['nixhomeserver.filesync.user.v1', 'cached-user'],
  ]);
  const state: { user?: string; error?: string } = { user: 'new-user' };
  let terminalRestore = false;
  let finishRestore!: () => void;
  const restore = new Function('startupGeneration', 'invoke', 'localStorage', 'SESSION_BACKUP_KEY', 'state', 'cacheSignedInUser', 'isTerminalSessionError', 'clearCachedSession', `${restoreSource}; return restoreSessionBackup;`)(
    startup,
    async (command: string) => {
      if (command === 'restore_session_backup') {
        if (terminalRestore) throw 'invalid_grant: session expired or was revoked';
        return await new Promise<void>((resolve) => { finishRestore = resolve; });
      }
      if (command === 'current_user') return 'old-user';
      throw new Error(`unexpected invoke: ${command}`);
    },
    { getItem: (key: string) => storage.get(key) ?? null },
    'nixhomeserver.filesync.session-backup.v1', state,
    (user: string) => { state.user = user; }, isTerminalSessionError,
    () => {
      state.user = undefined;
      storage.delete('nixhomeserver.filesync.user.v1');
      storage.delete('nixhomeserver.filesync.session-backup.v1');
    },
  ) as (generation: number) => Promise<boolean>;
  const pendingRestore = restore(oldGeneration);
  startup.begin();
  finishRestore();
  assert.equal(await pendingRestore, false);
  assert.equal(state.user, 'new-user');

  terminalRestore = true;
  state.user = 'cached-user';
  const terminalGeneration = startup.begin();
  assert.equal(await restore(terminalGeneration), false);
  assert.equal(state.user, undefined);
  assert.equal(storage.has('nixhomeserver.filesync.user.v1'), false);
  assert.equal(storage.has('nixhomeserver.filesync.session-backup.v1'), false);
  assert.match(state.error ?? '', /invalid_grant/);
});

test('actual callback handler lets the latest successful replacement own state in either response order', async () => {
  const source = readFileSync(new URL('./main.ts', import.meta.url), 'utf8');
  const start = source.indexOf('async function finishCallbackOnce(');
  const end = source.indexOf(String.fromCharCode(10) + 'const finishCallback =', start);
  assert.ok(start >= 0 && end > start, 'production callback handler is present');
  const handlerSource = source.slice(start, end)
    .replace('async function finishCallbackOnce(url: string): Promise<string | undefined> {', 'async function finishCallbackOnce(url) {')
    .replaceAll('invoke<string>(', 'invoke(')
    .replaceAll('invoke<boolean>(', 'invoke(')
    .replace('let generation: number | undefined;', 'let generation;');

  for (const responseOrder of [['old', 'new'], ['new', 'old']]) {
    const generation = createStartupGeneration();
    const ownership = createCallbackOwnership();
    const state: Record<string, unknown> = { user: undefined, offline: false, error: '', notice: '' };
    const resolvers = new Map<string, (user: string) => void>();
    const invoke = async (command: string, args?: { callbackUrl?: string }) => {
      if (command === 'finish_login') return await new Promise<string>((resolve) => { resolvers.set(args!.callbackUrl!, resolve); });
      if (command === 'settings_authorized') return true;
      if (command === 'session_backup') return null;
      if (command === 'server_presets') return [];
      if (command === 'update_background_syncs') return undefined;
      throw new Error(`unexpected invoke: ${command}`);
    };
    const handler = new Function('startupGeneration', 'callbackOwnership', 'invoke', 'state', 'cacheSignedInUser', 'saveSessionBackup', 'loadPresets', 'applySpacePrefsToPairs', 'persistPairs', 'render', 'refreshEstimates', `${handlerSource}; return finishCallbackOnce;`)(
      generation, ownership, invoke, state, (user: string) => { state.user = user; }, async () => undefined,
      async () => undefined, () => undefined, async () => undefined, () => undefined, async () => undefined,
    ) as (url: string) => Promise<string | undefined>;
    const oldCallback = handler('filesync://oauth/callback?old');
    const newCallback = handler('filesync://oauth/callback?new');
    resolvers.get(`filesync://oauth/callback?${responseOrder[0]}`)!(responseOrder[0]);
    await Promise.resolve();
    resolvers.get(`filesync://oauth/callback?${responseOrder[1]}`)!(responseOrder[1]);
    await Promise.all([oldCallback, newCallback]);
    assert.equal(state.user, 'new', `${responseOrder.join('-first')} response order`);
  }
});
