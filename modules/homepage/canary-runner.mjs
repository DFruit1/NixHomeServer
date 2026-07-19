import { spawn } from 'node:child_process';
import { createHmac } from 'node:crypto';
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { basename, join } from 'node:path';

const stateDir = process.env.CANARY_STATE_DIR ?? '/var/lib/homepage-canary';
const configPath = process.env.CANARY_CONFIG_FILE;
const passwordPath = process.env.CREDENTIALS_DIRECTORY
  ? join(process.env.CREDENTIALS_DIRECTORY, 'kanidm-password')
  : process.env.CANARY_PASSWORD_FILE;
const totpSeedPath = process.env.CREDENTIALS_DIRECTORY
  ? join(process.env.CREDENTIALS_DIRECTORY, 'kanidm-totp-seed')
  : process.env.CANARY_TOTP_SEED_FILE;
const driver = process.env.CHROMEDRIVER_BIN ?? 'chromedriver';
const chromium = process.env.CHROMIUM_BIN ?? 'chromium';
const driverPort = Number.parseInt(process.env.CANARY_DRIVER_PORT ?? '9515', 10);
const webdriverUrl = `http://127.0.0.1:${driverPort}`;
const elementKey = 'element-6066-11e4-a52e-4f735466cecf';

const now = () => new Date().toISOString();
const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const safeMessage = (error) => String(error instanceof Error ? error.message : error)
  .replace(/password\s*[=:]\s*\S+/gi, 'password=[redacted]')
  .slice(0, 1000);

const decodeBase32 = (value) => {
  const normalized = value.toUpperCase().replace(/[=\s-]/g, '');
  if (!/^[A-Z2-7]+$/.test(normalized)) throw new Error('canary TOTP seed is not valid base32');
  let bits = '';
  for (const character of normalized) {
    const index = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'.indexOf(character);
    bits += index.toString(2).padStart(5, '0');
  }
  const bytes = [];
  for (let offset = 0; offset + 8 <= bits.length; offset += 8) {
    bytes.push(Number.parseInt(bits.slice(offset, offset + 8), 2));
  }
  return Buffer.from(bytes);
};

export const generateTotp = (seed, {
  timestampMs = Date.now(), period = 30, digits = 6, algorithm = 'sha256',
} = {}) => {
  const counter = BigInt(Math.floor(timestampMs / 1000 / period));
  const message = Buffer.alloc(8);
  message.writeBigUInt64BE(counter);
  const digest = createHmac(algorithm, decodeBase32(seed)).update(message).digest();
  const offset = digest[digest.length - 1] & 0x0f;
  const binary = ((digest[offset] & 0x7f) << 24)
    | (digest[offset + 1] << 16)
    | (digest[offset + 2] << 8)
    | digest[offset + 3];
  return String(binary % (10 ** digits)).padStart(digits, '0');
};

const atomicJson = async (path, value) => {
  const temporary = `${path}.${process.pid}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o640 });
  await rename(temporary, path);
};

const request = async (path, method = 'GET', body) => {
  const response = await fetch(`${webdriverUrl}${path}`, {
    method,
    headers: body === undefined ? undefined : { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(35_000),
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || payload.value?.error) {
    throw new Error(`webdriver ${method} ${path}: ${payload.value?.error ?? response.status} ${payload.value?.message ?? ''}`.trim());
  }
  return payload.value;
};

const startDriver = async () => {
  const child = spawn(driver, [`--port=${driverPort}`, '--allowed-ips=127.0.0.1'], {
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (child.exitCode !== null) throw new Error(`chromedriver exited: ${stderr.slice(-500)}`);
    try {
      await request('/status');
      return child;
    } catch {
      await sleep(100);
    }
  }
  child.kill('SIGTERM');
  throw new Error('chromedriver did not become ready');
};

const createSession = async () => {
  const value = await request('/session', 'POST', {
    capabilities: {
      alwaysMatch: {
        browserName: 'chrome',
        acceptInsecureCerts: false,
        pageLoadStrategy: 'eager',
        timeouts: {
          pageLoad: 30_000,
          script: 30_000,
        },
        'goog:chromeOptions': {
          binary: chromium,
          args: [
            '--headless=new',
            '--disable-dev-shm-usage',
            '--disable-gpu',
            '--no-sandbox',
            '--no-first-run',
            '--no-default-browser-check',
            '--window-size=1280,900',
          ],
        },
      },
    },
  });
  return value.sessionId;
};

const sessionPath = (sessionId, path) => `/session/${sessionId}${path}`;
const navigate = (sessionId, url) => request(sessionPath(sessionId, '/url'), 'POST', { url });
const currentUrl = (sessionId) => request(sessionPath(sessionId, '/url'));
const execute = (sessionId, script, args = []) => request(sessionPath(sessionId, '/execute/sync'), 'POST', { script, args });
const closeSession = (sessionId) => request(`/session/${sessionId}`, 'DELETE').catch(() => undefined);
const reload = (sessionId) => request(sessionPath(sessionId, '/refresh'), 'POST', {});

export const isBlankRender = ({ textLength = 0, visibleElements = 0, richElements = 0 } = {}) =>
  visibleElements === 0 || (textLength < 20 && richElements === 0);

const pageMetricsScript = String.raw`
const visible = (element) => {
  const style = getComputedStyle(element);
  const rect = element.getBoundingClientRect();
  return style.display !== 'none' && style.visibility !== 'hidden' && Number(style.opacity) > 0
    && rect.width > 1 && rect.height > 1;
};
const elements = [...document.body?.querySelectorAll('*') ?? []].filter(visible);
const rich = elements.filter((element) => /^(A|BUTTON|INPUT|SELECT|TEXTAREA|IMG|SVG|CANVAS|VIDEO|MAIN|NAV)$/.test(element.tagName));
const text = (document.body?.innerText ?? '').replace(/\s+/g, ' ').trim();
const loginControls = elements.filter((element) => {
  if (element.matches('input[type="password"], input[autocomplete="current-password"], input[autocomplete="one-time-code"]')) return true;
  if (element.matches('form[action*="login" i], form[action*="auth" i]')) return true;
  if (!element.matches('button, input[type="submit"], a, [role="button"]')) return false;
  return /^(sign in|log in|login|authenticate|continue with (kanidm|openid|sso))$/i
    .test((element.innerText || element.value || element.textContent || '').replace(/\s+/g, ' ').trim());
}).length;
const navigation = performance.getEntriesByType('navigation')[0];
return {
  title: document.title,
  text: text.slice(0, 4000),
  textLength: text.length,
  visibleElements: elements.length,
  richElements: rich.length,
  loginControls,
  responseStatus: navigation?.responseStatus ?? 0,
};`;

const metrics = async (sessionId) => {
  const value = await execute(sessionId, pageMetricsScript);
  return { ...value, blank: isBlankRender(value) };
};
const hostOf = (url) => { try { return new URL(url).host; } catch { return ''; } };
export const hasAuthenticationBoundary = ({ url = '', text = '', title = '', loginControls = 0, authHost = '', kanidmHost = '' } = {}) =>
  [authHost, kanidmHost].filter(Boolean).includes(hostOf(url))
  || loginControls > 0
  || /(?:sign in|log in|authenticate|continue)\s+(?:to|with|using)\s+(?:kanidm|openid|oauth|single sign-on|sso)\b/i.test(`${title}\n${text}`);
const visibleElement = (sessionId, selectors) => execute(sessionId, String.raw`
const selectors = arguments[0];
for (const selector of selectors) {
  for (const element of document.querySelectorAll(selector)) {
    const rect = element.getBoundingClientRect();
    const style = getComputedStyle(element);
    if (rect.width > 1 && rect.height > 1 && style.display !== 'none' && style.visibility !== 'hidden') return element;
  }
}
return null;`, [selectors]);

const clickMatching = (sessionId, pattern) => execute(sessionId, String.raw`
const expression = new RegExp(arguments[0], 'i');
const candidates = [...document.querySelectorAll('button, a, [role="button"]')];
const target = candidates.find((element) => {
  const rect = element.getBoundingClientRect();
  return rect.width > 1 && rect.height > 1 && expression.test((element.innerText || element.textContent || '').trim());
});
if (!target) return false;
target.click();
return true;`, [pattern]);

const sendKeys = async (sessionId, element, value) => {
  const id = element?.[elementKey];
  if (!id) throw new Error('login input element was not found');
  await request(sessionPath(sessionId, `/element/${id}/clear`), 'POST', {});
  await request(sessionPath(sessionId, `/element/${id}/value`), 'POST', { text: value, value: [...value] });
};

const waitFor = async (callback, timeoutMs = 30_000, intervalMs = 250) => {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const value = await callback();
      if (value) return value;
    } catch (error) {
      lastError = error;
    }
    await sleep(intervalMs);
  }
  if (lastError) throw lastError;
  throw new Error(`timed out after ${timeoutMs}ms`);
};

const performKanidmLogin = async (sessionId, config, password, totpSeed) => {
  for (let step = 0; step < 8; step += 1) {
    const url = await currentUrl(sessionId);
    if (hostOf(url) !== hostOf(config.kanidmUrl)) return;
    const snapshot = await metrics(sessionId);
    const totpInput = await visibleElement(sessionId, [
      'input[autocomplete="one-time-code"]',
      'input[name*="totp" i]',
      'input[name*="otp" i]',
      'input[inputmode="numeric"]',
    ]);
    if (totpInput) {
      const secondsRemaining = 30 - (Math.floor(Date.now() / 1000) % 30);
      if (secondsRemaining < 3) await sleep((secondsRemaining + 1) * 1000);
      await sendKeys(sessionId, totpInput, generateTotp(totpSeed));
      await clickMatching(sessionId, 'continue|verify|sign in|log in|login|submit');
      await sleep(500);
      continue;
    }
    if (/security key|passkey/i.test(snapshot.text)) {
      const error = new Error('the canary account requires an unsupported passkey');
      error.code = 'unsupported-mfa';
      throw error;
    }
    const passwordInput = await visibleElement(sessionId, ['input[type="password"]', 'input[autocomplete="current-password"]']);
    if (passwordInput) {
      await sendKeys(sessionId, passwordInput, password);
      await clickMatching(sessionId, 'continue|sign in|log in|login|submit');
      await sleep(500);
      continue;
    }
    const usernameInput = /username/i.test(snapshot.text)
      ? await visibleElement(sessionId, ['input[autocomplete="username"]', 'input[name="username"]', 'input[type="text"]'])
      : null;
    if (usernameInput) {
      await sendKeys(sessionId, usernameInput, config.username);
      await clickMatching(sessionId, 'begin|continue|sign in|log in|login|submit');
      await sleep(500);
      continue;
    }
    if (/totp\s*(and|\+)\s*password/i.test(snapshot.text)) {
      const selected = await clickMatching(sessionId, 'totp.*password');
      if (selected) {
        await sleep(500);
        continue;
      }
    }
    await sleep(500);
  }
  const finalSnapshot = await metrics(sessionId).catch(() => ({ title: '', text: '' }));
  const error = new Error('Kanidm rejected the canary credential or did not complete login');
  error.code = 'setup-required';
  error.metrics = { ...finalSnapshot, text: finalSnapshot.text?.slice(0, 500) };
  throw error;
};

const renderCheck = async (sessionId, target, allowLoginSurface) => {
  let last;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    last = await waitFor(async () => {
      const value = await metrics(sessionId);
      return value.blank ? false : value;
    }).catch(async () => metrics(sessionId));
    const combined = `${last.title}\n${last.text}`;
    const titleMatches = new RegExp(target.expectedPattern, 'i').test(combined);
    const loginMatches = /sign in|log in|login|authenticate|kanidm|password/i.test(combined);
    if (!last.blank && (titleMatches || (allowLoginSurface && loginMatches))) {
      return { ...last, attempt: attempt + 1 };
    }
    if (attempt === 0) {
      await reload(sessionId);
      await sleep(2_000);
    }
  }
  const error = new Error(last?.blank ? 'page remained visually blank after reload' : 'expected application marker was not rendered');
  error.code = last?.blank ? 'blank-page' : 'marker-missing';
  error.metrics = last;
  throw error;
};

const classifyError = (error) => {
  if (error?.code) return error.code;
  const message = safeMessage(error).toLowerCase();
  if (message.includes('timed out') || message.includes('timeout')) return 'timeout';
  if (message.includes('dns') || message.includes('name_not_resolved')) return 'dns-error';
  if (message.includes('certificate') || message.includes('ssl') || message.includes('tls')) return 'tls-error';
  return 'runner-error';
};

const failureResult = (target, phase, error, startedAt) => ({
  id: target.id,
  name: target.name,
  coverageMode: target.coverageMode,
  status: 'failed',
  phase,
  failureCode: classifyError(error),
  message: safeMessage(error),
  durationMs: Date.now() - startedAt,
  metrics: error?.metrics,
});

const checkUnauthenticated = async (target) => {
  const startedAt = Date.now();
  const sessionId = await createSession();
  try {
    await navigate(sessionId, target.url);
    await sleep(750);
    let page;
    let finalUrl;
    await waitFor(async () => {
      page = await metrics(sessionId);
      finalUrl = await currentUrl(sessionId);
      if (page.blank) return false;
      return hasAuthenticationBoundary({
        url: finalUrl,
        text: page.text,
        title: page.title,
        loginControls: page.loginControls,
        authHost: target.authHost,
        kanidmHost: target.kanidmHost,
      });
    }, 10_000).catch(() => undefined);
    page ??= await metrics(sessionId);
    finalUrl ??= await currentUrl(sessionId);
    if (page.responseStatus >= 500) throw Object.assign(new Error(`HTTP ${page.responseStatus}`), { code: 'http-error', metrics: page });
    if (!hasAuthenticationBoundary({
      url: finalUrl,
      text: page.text,
      title: page.title,
      loginControls: page.loginControls,
      authHost: target.authHost,
      kanidmHost: target.kanidmHost,
    })) {
      throw Object.assign(new Error('unauthenticated browser reached content without an authentication boundary'), {
        code: 'unauthorized-content-exposed', metrics: page,
      });
    }
    return {
      id: target.id, name: target.name, coverageMode: target.coverageMode, status: 'passed', phase: 'unauthenticated',
      finalUrl, durationMs: Date.now() - startedAt, metrics: { ...page, text: undefined },
    };
  } catch (error) {
    return failureResult(target, 'unauthenticated', error, startedAt);
  } finally {
    await closeSession(sessionId);
  }
};

const checkAuthenticated = async (sessionId, target) => {
  const startedAt = Date.now();
  try {
    await navigate(sessionId, target.url);
    await sleep(750);
    if (target.coverageMode === 'native-oidc') {
      const current = await metrics(sessionId);
      if (/sign in|log in|login|openid|oauth|kanidm/i.test(current.text)) {
        const clicked = await clickMatching(sessionId, 'kanidm|openid|oauth|single sign|sso');
        if (clicked) await sleep(750);
      }
      if (hostOf(await currentUrl(sessionId)) === target.kanidmHost) {
        await waitFor(async () => hostOf(await currentUrl(sessionId)) !== target.kanidmHost);
      }
    }
    const boundaryOnly = target.coverageMode === 'local-boundary' || target.coverageMode === 'gateway-boundary';
    const page = await renderCheck(sessionId, target, boundaryOnly);
    const finalUrl = await currentUrl(sessionId);
    if (page.responseStatus >= 400) throw Object.assign(new Error(`HTTP ${page.responseStatus}`), { code: 'http-error', metrics: page });
    if (hostOf(finalUrl) !== hostOf(target.url)) {
      throw Object.assign(new Error(`expected host ${hostOf(target.url)}, reached ${hostOf(finalUrl)}`), { code: 'wrong-host', metrics: page });
    }
    return {
      id: target.id, name: target.name, coverageMode: target.coverageMode, status: 'passed', phase: 'authenticated',
      finalUrl, durationMs: Date.now() - startedAt, metrics: { ...page, text: undefined },
    };
  } catch (error) {
    return failureResult(target, 'authenticated', error, startedAt);
  }
};

const pruneFailures = async () => {
  const directory = join(stateDir, 'failures');
  const cutoff = Date.now() - 14 * 24 * 60 * 60 * 1000;
  const { readdir, stat } = await import('node:fs/promises');
  for (const entry of await readdir(directory).catch(() => [])) {
    const path = join(directory, entry);
    const info = await stat(path).catch(() => undefined);
    if (info?.isFile() && info.mtimeMs < cutoff) await rm(path, { force: true });
  }
};

const main = async () => {
  if (!configPath || !passwordPath || !totpSeedPath) throw new Error('canary configuration or credential path is missing');
  const config = JSON.parse(await readFile(configPath, 'utf8'));
  const password = (await readFile(passwordPath, 'utf8')).trim();
  const totpSeed = (await readFile(totpSeedPath, 'utf8')).trim();
  if (!password) throw new Error('canary password is empty');
  if (!totpSeed) throw new Error('canary TOTP seed is empty');
  await mkdir(join(stateDir, 'failures'), { recursive: true, mode: 0o750 });
  await pruneFailures();

  const runId = `${new Date().toISOString().replace(/[:.]/g, '-')}-${process.pid}`;
  const startedAt = now();
  const running = { schemaVersion: 1, runId, state: 'running', startedAt };
  await atomicJson(join(stateDir, 'running.json'), running);

  let driverProcess;
  try {
    driverProcess = await startDriver();
    const results = [];
    for (const target of config.targets) results.push(await checkUnauthenticated({ ...target, authHost: config.authHost, kanidmHost: hostOf(config.kanidmUrl) }));

    const unauthFailures = new Set(results.filter((result) => result.status === 'failed').map((result) => result.id));
    const authSession = await createSession();
    try {
      await navigate(authSession, config.homepageUrl);
      await performKanidmLogin(authSession, config, password, totpSeed);
      await waitFor(async () => hostOf(await currentUrl(authSession)) === hostOf(config.homepageUrl));
      for (const target of config.targets) {
        if (unauthFailures.has(target.id)) continue;
        results.push(await checkAuthenticated(authSession, { ...target, kanidmHost: hostOf(config.kanidmUrl) }));
      }
    } catch (error) {
      for (const target of config.targets.filter((candidate) => !unauthFailures.has(candidate.id))) {
        results.push(failureResult(target, 'login', error, Date.now()));
      }
    } finally {
      await closeSession(authSession);
    }

    const failures = results.filter((result) => result.status === 'failed');
    const completed = {
      schemaVersion: 1,
      runId,
      state: failures.length === 0 ? 'passed' : failures.some((failure) => failure.failureCode === 'setup-required') ? 'setup-required' : 'failed',
      startedAt,
      finishedAt: now(),
      targetCount: config.targets.length,
      failureCount: failures.length,
      results,
    };
    await atomicJson(join(stateDir, 'latest.json'), completed);
    if (failures.length > 0) await atomicJson(join(stateDir, 'failures', `${runId}.json`), completed);
    return failures.length === 0 ? 0 : 1;
  } finally {
    driverProcess?.kill('SIGTERM');
    await rm(join(stateDir, 'running.json'), { force: true });
  }
};

if (process.env.CANARY_RUNNER_TEST_MODE !== '1') {
  try {
    process.exitCode = await main();
  } catch (error) {
    const runId = `runner-${new Date().toISOString().replace(/[:.]/g, '-')}`;
    const record = {
      schemaVersion: 1,
      runId,
      state: 'failed',
      startedAt: now(),
      finishedAt: now(),
      targetCount: 0,
      failureCount: 1,
      results: [{ id: 'runner', name: basename(import.meta.url), coverageMode: 'internal', status: 'failed', phase: 'runner', failureCode: classifyError(error), message: safeMessage(error), durationMs: 0 }],
    };
    await mkdir(join(stateDir, 'failures'), { recursive: true, mode: 0o750 }).catch(() => undefined);
    await atomicJson(join(stateDir, 'latest.json'), record).catch(() => undefined);
    await atomicJson(join(stateDir, 'failures', `${runId}.json`), record).catch(() => undefined);
    await rm(join(stateDir, 'running.json'), { force: true }).catch(() => undefined);
    process.stderr.write(`canary runner failed: ${safeMessage(error)}\n`);
    process.exitCode = 2;
  }
}
