#!/usr/bin/env node

import fs from "node:fs/promises";
import crypto from "node:crypto";
import process from "node:process";
import { pathToFileURL } from "node:url";

const snapshotJson = process.env.RUNTIME_HEALTH_SNAPSHOT;
if (!snapshotJson) {
  console.error("RUNTIME_HEALTH_SNAPSHOT is required");
  process.exit(1);
}

const playwrightModule = process.env.PLAYWRIGHT_NODE_MODULE;
if (!playwrightModule) {
  console.error("PLAYWRIGHT_NODE_MODULE is required");
  process.exit(1);
}

const mode = process.argv[2];
if (!mode || !["bootstrap", "verify"].includes(mode)) {
  console.error("usage: runtime-access-browser-check.mjs <bootstrap|verify>");
  process.exit(1);
}

const snapshot = JSON.parse(snapshotJson);
const { chromium } = await import(pathToFileURL(playwrightModule).href);

const chromiumExecutable =
  process.env.RUNTIME_ACCESS_BROWSER_EXECUTABLE || "chromium";
const totpSecretsByAccount = new Map();

function collapseWhitespace(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function lower(value) {
  return String(value || "").toLowerCase();
}

function accessResult({
  scope,
  app,
  canary = null,
  severity,
  detail,
  finalUrl = null,
  httpCode = null,
}) {
  return {
    scope,
    app,
    canary,
    severity,
    detail,
    finalUrl,
    httpCode,
  };
}

async function readTrimmed(filePath) {
  return (await fs.readFile(filePath, "utf8")).trim();
}

function decodeBase32(value) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  const normalized = String(value || "")
    .toUpperCase()
    .replace(/=+$/g, "")
    .replace(/\s+/g, "");
  let bits = "";

  for (const character of normalized) {
    const index = alphabet.indexOf(character);
    if (index < 0) {
      throw new Error(`invalid base32 character '${character}'`);
    }
    bits += index.toString(2).padStart(5, "0");
  }

  const bytes = [];
  for (let offset = 0; offset + 8 <= bits.length; offset += 8) {
    bytes.push(Number.parseInt(bits.slice(offset, offset + 8), 2));
  }
  return Buffer.from(bytes);
}

function generateTotp(secret, { algorithm = "sha256", digits = 6, period = 30 } = {}) {
  const counter = Math.floor(Date.now() / 1000 / period);
  const buffer = Buffer.alloc(8);
  buffer.writeBigUInt64BE(BigInt(counter));

  const hmac = crypto
    .createHmac(algorithm.toLowerCase(), decodeBase32(secret))
    .update(buffer)
    .digest();
  const offset = hmac[hmac.length - 1] & 0x0f;
  const binary =
    ((hmac[offset] & 0x7f) << 24) |
    ((hmac[offset + 1] & 0xff) << 16) |
    ((hmac[offset + 2] & 0xff) << 8) |
    (hmac[offset + 3] & 0xff);

  return String(binary % 10 ** digits).padStart(digits, "0");
}

async function waitForStableTotpWindow(period = 30) {
  const remaining = period - (Math.floor(Date.now() / 1000) % period);
  if (remaining <= 5) {
    await new Promise((resolve) => setTimeout(resolve, (remaining + 1) * 1000));
  }
}

async function loadBootstrapTotpSecrets() {
  const stateFile = process.env.RUNTIME_ACCESS_BOOTSTRAP_STATE_FILE;
  if (!stateFile) {
    return;
  }

  const state = JSON.parse(await fs.readFile(stateFile, "utf8"));
  for (const result of state.resetResults || []) {
    if (result.accountId && result.totpSecret) {
      totpSecretsByAccount.set(result.accountId, {
        secret: result.totpSecret,
        algorithm: result.totpAlgorithm || "SHA256",
        digits: result.totpDigits || 6,
        period: result.totpPeriod || 30,
      });
    }
  }
}

function findCanary(accountId) {
  return snapshot.accessChecks.canaries.find(
    (canary) => canary.accountId === accountId,
  );
}

function expectedAppNames(canary) {
  return new Set((canary.expectedApps || []).map((app) => app.name));
}

function trackedApps() {
  return snapshot.accessChecks.apps.filter((app) => app.name !== "vaultwarden");
}

function kanidmBaseUrl() {
  return (
    snapshot.services?.edgeHttp?.find((service) => service.name === "kanidm")
      ?.url || ""
  ).replace(/\/$/, "");
}

async function launchBrowser() {
  return chromium.launch({
    executablePath: chromiumExecutable,
    headless: true,
    args: ["--no-sandbox", "--disable-dev-shm-usage"],
  });
}

async function newPage(browser) {
  const context = await browser.newContext({
    ignoreHTTPSErrors: true,
  });
  const page = await context.newPage();
  const responses = [];
  page.on("response", (response) => {
    responses.push({
      url: response.url(),
      status: response.status(),
    });
  });
  return { context, page, responses };
}

async function waitForSettled(page, timeout = 20000) {
  await page.waitForLoadState("domcontentloaded", { timeout }).catch(() => {});
  await page.waitForLoadState("networkidle", { timeout }).catch(() => {});
}

async function waitForBodyMatch(page, pattern, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const body = await page.locator("body").innerText().catch(() => "");
    if (pattern.test(body)) {
      return true;
    }
    await page.waitForTimeout(250);
  }
  return false;
}

async function visibleLocator(page, selectors) {
  for (const selector of selectors) {
    const locator = page.locator(selector).first();
    const count = await locator.count().catch(() => 0);
    if (count === 0) {
      continue;
    }
    if (await locator.isVisible().catch(() => false)) {
      return locator;
    }
  }
  return null;
}

async function pageSignals(page, responses) {
  await waitForSettled(page);
  const finalUrl = page.url();
  const title = await page.title().catch(() => "");
  const body = collapseWhitespace(
    await page.locator("body").innerText().catch(() => ""),
  );

  const matchingResponse = [...responses]
    .reverse()
    .find((response) => response.url === finalUrl);
  const latestResponse = [...responses].reverse()[0] || null;

  return {
    finalUrl,
    title,
    body,
    httpCode: matchingResponse?.status ?? latestResponse?.status ?? null,
  };
}

async function submitForm(page) {
  const submit = await visibleLocator(page, [
    'button[type="submit"]',
    'input[type="submit"]',
    'button:has-text("Sign In")',
    'button:has-text("Login")',
    'button:has-text("Continue")',
    'button:has-text("Submit")',
  ]);
  if (submit) {
    await submit.click();
    return;
  }

  const password = await visibleLocator(page, ['input[type="password"]']);
  if (password) {
    await password.press("Enter");
    return;
  }

  throw new Error("no visible submit control");
}

async function loginToKanidm(page, canary) {
  const passwordFile = `/run/agenix/${canary.passwordSecret}`;
  const passwordValue = await readTrimmed(passwordFile);
  const totp = totpSecretsByAccount.get(canary.accountId);
  const usernameSelectors = [
    'input[name="username"]',
    'input[name="account"]',
    'input[autocomplete="username"]',
    'input[type="email"]',
  ];
  const passwordSelectors = ['input[type="password"]'];
  const totpSelectors = [
    'input[name="totp"]',
    'input[name="token"]',
    'input[name="code"]',
    'input[name="otp"]',
    'input[inputmode="numeric"]',
    'input[autocomplete="one-time-code"]',
  ];

  for (let step = 0; step < 6; step += 1) {
    const username = await visibleLocator(page, usernameSelectors);
    const password = await visibleLocator(page, passwordSelectors);
    const totpInput = await visibleLocator(page, totpSelectors);

    if (step > 0 && !username && !password && !totpInput) {
      return;
    }

    if (totpInput) {
      if (!totp) {
        throw new Error(`kanidm requested TOTP for ${canary.accountId} but no bootstrap TOTP secret is available`);
      }

      await waitForStableTotpWindow(totp.period);
      await totpInput.fill(
        generateTotp(totp.secret, {
          algorithm: totp.algorithm,
          digits: totp.digits,
          period: totp.period,
        }),
      );
      await submitForm(page);
      await waitForSettled(page, 10000);
      continue;
    }

    if (username && !password) {
      await username.fill(canary.accountId);
      await submitForm(page);
      await waitForSettled(page, 10000);
      continue;
    }

    if (password) {
      if (username) {
        await username.fill(canary.accountId);
      }
      await password.fill(passwordValue);
      await submitForm(page);
      await waitForSettled(page, 10000);
      continue;
    }
  }

  throw new Error("kanidm login form not detected");
}

function signalsLookUnauthenticated(signals) {
  const url = lower(signals.finalUrl);
  const title = lower(signals.title);
  const body = lower(signals.body);

  return (
    url.includes("/login") ||
    url.includes("/auth/login") ||
    url.includes("/accounts/login") ||
    url.includes("/signin") ||
    body.includes("login with kanidm") ||
    body.includes("sign in with kanidm") ||
    body.includes("single sign-on")
  );
}

async function kickOffAppLogin(page) {
  const selectors = [
    'button:has-text("Login with Kanidm")',
    'a:has-text("Login with Kanidm")',
    'button:has-text("Sign in with Kanidm")',
    'a:has-text("Sign in with Kanidm")',
    'button:has-text("Kanidm")',
    'button:has-text("Single Sign-On")',
    'a:has-text("Single Sign-On")',
    'button:has-text("SSO")',
    'a:has-text("SSO")',
    'form[action*="/oidc/"] button[type="submit"]',
    'form[action*="/oidc/"] button',
    'button[formaction*="/oidc/"]',
    'a[href*="/oidc/"]',
    'a[href*="/oauth2/"]',
  ];

  const baseUrl = kanidmBaseUrl();
  if (baseUrl && page.url().startsWith(baseUrl)) {
    selectors.push(
      'button:has-text("Allow")',
      'button:has-text("Accept")',
      'button:has-text("Proceed")',
      'button:has-text("Continue")',
      'button:has-text("Submit")',
    );
  }

  const kickoff = await visibleLocator(page, selectors);

  if (!kickoff) {
    return false;
  }

  const beforeUrl = page.url();
  await kickoff.click().catch((error) => {
    const baseUrl = kanidmBaseUrl();
    if (baseUrl && beforeUrl !== page.url() && page.url().startsWith(baseUrl)) {
      return;
    }
    throw error;
  });
  await page
    .waitForURL((url) => url.href !== beforeUrl, { timeout: 10000 })
    .catch(() => {});
  await waitForSettled(page, 10000);
  return true;
}

async function resumeKanidmOAuth(page) {
  const baseUrl = kanidmBaseUrl();
  if (!baseUrl || !page.url().startsWith(`${baseUrl}/ui/oauth2/resume`)) {
    return false;
  }

  const beforeUrl = page.url();
  const proceed = await visibleLocator(page, [
    'button:has-text("Proceed")',
    'button:has-text("Allow")',
    'button:has-text("Accept")',
    'button:has-text("Continue")',
    'button[type="submit"]',
  ]);
  if (!proceed) {
    return false;
  }

  await proceed.click();
  await page
    .waitForURL((url) => url.href !== beforeUrl, { timeout: 10000 })
    .catch(() => {});
  await waitForSettled(page, 10000);
  return true;
}

async function pageHasKanidmLogin(page) {
  const baseUrl = kanidmBaseUrl();
  if (baseUrl && !page.url().startsWith(baseUrl)) {
    return false;
  }

  return Boolean(
    await visibleLocator(page, [
      'form#login',
      'input[name="username"]',
      'input[type="password"]',
      'button:has-text("Begin")',
    ]),
  );
}

function markerMatches(app, signals) {
  const marker = app.verification?.markerText;
  if (!marker) {
    return true;
  }

  const markerLower = lower(marker);
  return (
    lower(signals.title).includes(markerLower) ||
    lower(signals.body).includes(markerLower) ||
    lower(signals.finalUrl).includes(markerLower)
  );
}

async function filebrowserHasAnySignal(page, signals) {
  for (const signal of signals) {
    for (const selector of signal.selectors || []) {
      const locator = page.locator(selector).first();
      if ((await locator.count().catch(() => 0)) > 0) {
        return true;
      }
    }
  }

  const body = lower(await page.locator("body").innerText().catch(() => ""));
  return signals.some((signal) =>
    (signal.bodyText || []).some((text) => body.includes(lower(text))),
  );
}

async function verifyFilebrowserUserLevelAccess(page, canary) {
  if (canary.accountId !== "canary-files") {
    return null;
  }

  const personalVisible = await filebrowserHasAnySignal(page, [
    {
      selectors: [
        'a:has-text("Personal")',
        'button:has-text("Personal")',
        '[data-source-name="Personal"]',
      ],
      bodyText: ["Personal", "Files"],
    },
  ]);
  if (!personalVisible) {
    return "personal file source was not visible after login";
  }

  const sharedVisible = await filebrowserHasAnySignal(page, [
    {
      selectors: [
        'a[href*="shared"]',
        'a:has-text("Shared")',
        'button:has-text("Shared")',
        '[data-source-name="Shared"]',
      ],
      bodyText: ["Shared"],
    },
  ]);
  if (!sharedVisible) {
    return "shared file source was not visible after login";
  }

  const adminVisible = await filebrowserHasAnySignal(page, [
    {
      selectors: [
        'a[href*="/admin"]',
        'a[href*="/users"]',
        'button:has-text("Administration")',
        'a:has-text("Administration")',
        'button:has-text("User Management")',
        'a:has-text("User Management")',
      ],
      bodyText: ["Administration", "User Management"],
    },
  ]);
  if (adminVisible) {
    return "admin controls were visible to the runtime access canary";
  }

  return null;
}

async function verifyCopypartyPersonalUploadAccess(page, canary, app) {
  if (app.name !== "uploads" || canary.accountId !== "canary-files") {
    return null;
  }

  const personalUrl = new URL(`${canary.accountId}/`, app.entryUrl).href;
  const response = await page.goto(personalUrl, { waitUntil: "domcontentloaded" });
  await waitForSettled(page, 10000);

  const signals = await pageSignals(page, [
    {
      url: page.url(),
      status: response?.status() ?? null,
    },
  ]);
  if (
    response &&
    (response.status() < 200 || response.status() >= 400)
  ) {
    return `personal upload root returned HTTP ${response.status()}`;
  }

  if (!signals.finalUrl.startsWith(app.verification.finalUrlPrefix)) {
    return `personal upload root left ${app.verification.finalUrlPrefix} for ${signals.finalUrl}`;
  }

  if (deniedBySignals(app, signals)) {
    return "personal upload root was denied after login";
  }

  return null;
}

async function reachApp(browser, canary, app) {
  const { context, page, responses } = await newPage(browser);

  try {
    await page.goto(app.entryUrl, { waitUntil: "domcontentloaded" });
    await waitForSettled(page, 10000);

    const initialSignals = await pageSignals(page, responses);
    const alreadyAtApp =
      initialSignals.finalUrl.startsWith(app.verification.finalUrlPrefix) &&
      markerMatches(app, initialSignals);

    if (!alreadyAtApp) {
      await loginToKanidm(page, canary);
    }

    const finalSignals = await pageSignals(page, responses);
    return { page, signals: finalSignals };
  } catch (error) {
    throw new Error(`${app.name}: ${error.message}`);
  } finally {
    await context.close();
  }
}

async function verifyPositiveAccess(browser, canary, app) {
  const { context, page, responses } = await newPage(browser);

  try {
    await page.goto(app.entryUrl, { waitUntil: "domcontentloaded" });
    await waitForSettled(page, 10000);

    let finalSignals = await pageSignals(page, responses);

    for (let step = 0; step < 5; step += 1) {
      const landedOnApp = finalSignals.finalUrl.startsWith(
        app.verification.finalUrlPrefix,
      );
      const markerOk = markerMatches(app, finalSignals);
      const authenticated =
        landedOnApp && markerOk && !signalsLookUnauthenticated(finalSignals);

      if (authenticated) {
        if (app.name === "files") {
          const filebrowserError = await verifyFilebrowserUserLevelAccess(
            page,
            canary,
          );
          if (filebrowserError) {
            return accessResult({
              scope: "authed",
              app: app.name,
              canary: canary.accountId,
              severity: "CRITICAL",
              detail: filebrowserError,
              finalUrl: finalSignals.finalUrl,
              httpCode: finalSignals.httpCode,
            });
          }
        }
        if (app.name === "uploads") {
          const uploadError = await verifyCopypartyPersonalUploadAccess(
            page,
            canary,
            app,
          );
          if (uploadError) {
            return accessResult({
              scope: "authed",
              app: app.name,
              canary: canary.accountId,
              severity: "CRITICAL",
              detail: uploadError,
              finalUrl: page.url(),
              httpCode: finalSignals.httpCode,
            });
          }
        }

        return accessResult({
          scope: "authed",
          app: app.name,
          canary: canary.accountId,
          severity: "OK",
          detail: `landed on ${finalSignals.finalUrl}`,
          finalUrl: finalSignals.finalUrl,
          httpCode: finalSignals.httpCode,
        });
      }

      if (await resumeKanidmOAuth(page)) {
        // The Kanidm consent page submitted successfully.
      } else if (await pageHasKanidmLogin(page)) {
        await loginToKanidm(page, canary);
      } else if (await kickOffAppLogin(page)) {
        // The app-specific login button redirected us into OIDC.
      } else {
        break;
      }

      finalSignals = await pageSignals(page, responses);
    }

    return accessResult({
      scope: "authed",
      app: app.name,
      canary: canary.accountId,
      severity: "CRITICAL",
      detail: `expected authenticated landing under ${app.verification.finalUrlPrefix} but reached ${finalSignals.finalUrl}`,
      finalUrl: finalSignals.finalUrl,
      httpCode: finalSignals.httpCode,
    });
  } catch (error) {
    return accessResult({
      scope: "authed",
      app: app.name,
      canary: canary.accountId,
      severity: "CRITICAL",
      detail: error.message,
    });
  } finally {
    await context.close();
  }
}

function deniedBySignals(app, signals) {
  if ([401, 403].includes(signals.httpCode)) {
    return true;
  }

  const body = lower(signals.body);
  const title = lower(signals.title);
  return (
    body.includes("403") ||
    body.includes("forbidden") ||
    body.includes("access denied") ||
    title.includes("403") ||
    title.includes("forbidden") ||
    title.includes("access denied") ||
    lower(signals.finalUrl).includes("/oauth2/") ||
    !signals.finalUrl.startsWith(app.verification.finalUrlPrefix)
  );
}

async function verifyNegativeAccess(browser, canary, app) {
  const { context, page, responses } = await newPage(browser);

  try {
    await page.goto(app.entryUrl, { waitUntil: "domcontentloaded" });
    await waitForSettled(page, 10000);
    await loginToKanidm(page, canary);
    const finalSignals = await pageSignals(page, responses);

    const unexpectedlyAllowed =
      finalSignals.finalUrl.startsWith(app.verification.finalUrlPrefix) &&
      markerMatches(app, finalSignals);
    if (unexpectedlyAllowed) {
      return accessResult({
        scope: "authed",
        app: app.name,
        canary: canary.accountId,
        severity: "CRITICAL",
        detail: `unexpectedly gained access to ${app.name}`,
        finalUrl: finalSignals.finalUrl,
        httpCode: finalSignals.httpCode,
      });
    }

    if (!deniedBySignals(app, finalSignals)) {
      return accessResult({
        scope: "authed",
        app: app.name,
        canary: canary.accountId,
        severity: "CRITICAL",
        detail: `did not observe a stable denial outcome after login`,
        finalUrl: finalSignals.finalUrl,
        httpCode: finalSignals.httpCode,
      });
    }

    return accessResult({
      scope: "authed",
      app: app.name,
      canary: canary.accountId,
      severity: "OK",
      detail: `denied as expected`,
      finalUrl: finalSignals.finalUrl,
      httpCode: finalSignals.httpCode,
    });
  } catch (error) {
    return accessResult({
      scope: "authed",
      app: app.name,
      canary: canary.accountId,
      severity: "CRITICAL",
      detail: error.message,
    });
  } finally {
    await context.close();
  }
}

async function setPasswordFromReset(browser, resetSpec) {
  const { context, page } = await newPage(browser);

  try {
    const passwordValue = await readTrimmed(resetSpec.passwordFile);
    await page.goto(resetSpec.resetUrl, { waitUntil: "domcontentloaded" });
    await waitForSettled(page, 10000);

    const passwordFields = page.locator('input[type="password"]');
    let count = await passwordFields.count();
    if (count < 2) {
      const addPassword = await visibleLocator(page, [
        'button[hx-post="/ui/reset/add_password"]',
        'button[hx-post="/ui/reset/change_password"]',
        'button:has-text("Add Password")',
        'button:has-text("Change Password")',
      ]);
      if (addPassword) {
        await addPassword.click();
        await page.waitForSelector('input[type="password"]', { timeout: 10000 });
        await waitForSettled(page, 10000);
        count = await passwordFields.count();
      }
    }
    if (count < 2) {
      throw new Error("reset form did not expose two password fields");
    }

    await passwordFields.nth(0).fill(passwordValue);
    await passwordFields.nth(1).fill(passwordValue);
    await submitForm(page);
    await waitForSettled(page, 10000);
    await waitForBodyMatch(
      page,
      /Multi-Factor Authentication is required|Add TOTP|Registered authenticators|Save Changes|Login/i,
    );

    let totpSecret = null;
    let totpAlgorithm = "SHA256";
    let totpDigits = 6;
    let totpPeriod = 30;
    let signals = await pageSignals(page, []);
    if (
      lower(signals.body).includes("multi-factor authentication is required") ||
      (await visibleLocator(page, ['button[hx-post="/ui/reset/add_totp"]', 'button:has-text("Add TOTP")']))
    ) {
      const addTotp = await visibleLocator(page, [
        'button[hx-post="/ui/reset/add_totp"]',
        'button:has-text("Add TOTP")',
      ]);
      if (!addTotp) {
        throw new Error("kanidm requires MFA but the reset page did not expose Add TOTP");
      }

      await addTotp.click();
      await page.waitForSelector("#new-totp-check", { timeout: 10000 });
      await waitForSettled(page, 10000);

      const totpBody = await page.locator("body").innerText();
      const secretMatch = totpBody.match(/Secret:\s*([A-Z2-7]+)/i);
      if (!secretMatch) {
        throw new Error("kanidm TOTP setup did not expose a secret");
      }
      totpSecret = secretMatch[1].toUpperCase();
      totpAlgorithm = totpBody.match(/Algorithm:\s*([A-Z0-9-]+)/i)?.[1] || "SHA256";
      totpPeriod = Number(totpBody.match(/Time Steps:\s*([0-9]+)/i)?.[1] || 30);
      totpDigits = Number(totpBody.match(/Code size:\s*([0-9]+)/i)?.[1] || 6);

      await waitForStableTotpWindow(totpPeriod);
      await page
        .locator("#new-totp-name")
        .fill(`runtime-access-canary-${Date.now()}`);
      await page.locator("#new-totp-check").fill(
        generateTotp(totpSecret, {
          algorithm: totpAlgorithm,
          digits: totpDigits,
          period: totpPeriod,
        }),
      );
      await page.locator("#totp-submit").click();
      await waitForSettled(page, 10000);
      await waitForBodyMatch(page, /Registered authenticators|Save Changes/i);
    }

    await page
      .waitForFunction(
        () =>
          [...document.querySelectorAll("button")].some(
            (button) =>
              button.textContent?.includes("Save Changes") && !button.disabled,
          ),
        null,
        { timeout: 10000 },
      )
      .catch(() => {});
    const saveChanges = await visibleLocator(page, ['button:has-text("Save Changes")']);
    if (saveChanges) {
      if (!(await saveChanges.isEnabled().catch(() => false))) {
        throw new Error("kanidm reset changes could not be saved; Save Changes remained disabled");
      }
      await saveChanges.click();
      await page.waitForURL((url) => !url.href.includes("/ui/reset"), { timeout: 10000 }).catch(() => {});
      await waitForSettled(page, 10000);
      await page.waitForTimeout(1500);
    }

    signals = await pageSignals(page, []);
    const resetStillVisible = lower(signals.finalUrl).includes("reset");
    const body = lower(signals.body);
    const title = lower(signals.title);

    if (
      resetStillVisible &&
      !body.includes("login") &&
      !body.includes("success") &&
      !title.includes("login")
    ) {
      throw new Error(`password reset did not leave the reset flow; final URL ${signals.finalUrl}`);
    }

    return {
      accountId: resetSpec.accountId,
      severity: "OK",
      detail: "password reset completed",
      finalUrl: signals.finalUrl,
      ...(totpSecret
        ? {
            totpSecret,
            totpAlgorithm,
            totpDigits,
            totpPeriod,
          }
        : {}),
    };
  } catch (error) {
    return {
      accountId: resetSpec.accountId,
      severity: "CRITICAL",
      detail: error.message,
      finalUrl: null,
    };
  } finally {
    await context.close();
  }
}

async function bootstrap() {
  const resetTokensFile = process.env.RUNTIME_ACCESS_RESET_TOKENS_FILE;
  if (!resetTokensFile) {
    throw new Error("RUNTIME_ACCESS_RESET_TOKENS_FILE is required for bootstrap mode");
  }

  const resetSpecs = JSON.parse(await fs.readFile(resetTokensFile, "utf8"));
  const browser = await launchBrowser();

  try {
    const resetResults = [];
    const warmupResults = [];

    for (const resetSpec of resetSpecs) {
      const resetResult = await setPasswordFromReset(browser, resetSpec);
      resetResults.push(resetResult);

      if (resetResult.severity !== "OK") {
        continue;
      }
      if (resetResult.totpSecret) {
        totpSecretsByAccount.set(resetSpec.accountId, {
          secret: resetResult.totpSecret,
          algorithm: resetResult.totpAlgorithm || "SHA256",
          digits: resetResult.totpDigits || 6,
          period: resetResult.totpPeriod || 30,
        });
      }

      const canary = findCanary(resetSpec.accountId);
      if (!canary) {
        continue;
      }

      const allowedApps = trackedApps().filter((app) =>
        expectedAppNames(canary).has(app.name),
      );
      for (const app of allowedApps) {
        warmupResults.push(await verifyPositiveAccess(browser, canary, app));
      }
    }

    process.stdout.write(
      JSON.stringify(
        {
          timestamp: new Date().toISOString(),
          resetResults,
          warmupResults,
        },
        null,
        2,
      ),
    );
  } finally {
    await browser.close();
  }
}

async function verify() {
  await loadBootstrapTotpSecrets();
  const browser = await launchBrowser();

  try {
    const results = [];
    const apps = trackedApps();

    for (const canary of snapshot.accessChecks.canaries) {
      const allowedApps = expectedAppNames(canary);

      for (const app of apps) {
        if (allowedApps.has(app.name)) {
          results.push(await verifyPositiveAccess(browser, canary, app));
          continue;
        }

        if (app.kind === "oauth2-proxy") {
          results.push(await verifyNegativeAccess(browser, canary, app));
        }
      }
    }

    process.stdout.write(`${JSON.stringify(results, null, 2)}\n`);
  } finally {
    await browser.close();
  }
}

if (mode === "bootstrap") {
  await bootstrap();
} else {
  await verify();
}
