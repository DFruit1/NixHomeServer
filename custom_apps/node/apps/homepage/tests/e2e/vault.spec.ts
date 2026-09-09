import { expect, test, type Page } from '@playwright/test';

const allAccessGroups = 'users files-sftp-users freshrss-users kavita-users';
const vaultPassword = 'vault-pass';
const totpCode = '654321';
const validPublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDECtGBZcPahwDCtWiMgn24qGdqMOJhPpHoPpKsHAF laptop';

test.beforeEach(async ({ page }) => {
  page.on('pageerror', (error) => {
    throw error;
  });
});

const identityHeaders = (username: string, groups: string) => ({
  'x-forwarded-preferred-username': username,
  'x-forwarded-groups': groups,
});

const unlockThroughApi = async (page: Page, baseURL: string, username: string, groups: string, password = vaultPassword) => {
  const headers = {
    ...identityHeaders(username, groups),
    origin: baseURL,
    'sec-fetch-site': 'same-origin',
  };
  await page.setExtraHTTPHeaders(identityHeaders(username, groups));
  const response = await page.request.post('/api/vault/session', { data: { password }, headers });
  if (response.status() === 200) {
    const body = await response.json();
    if (body.totpRequired) {
      const totpResponse = await page.request.post('/api/vault/session', {
        data: { pendingId: body.pendingId, totp: totpCode },
        headers,
      });
      expect(totpResponse.ok()).toBeTruthy();
    }
  } else {
    expect(response.status()).toBe(401);
    throw new Error('unlock through api failed');
  }
};

test('the vault stays locked until a correct second sign-in', async ({ page, baseURL }) => {
  await page.setExtraHTTPHeaders({
    'x-forwarded-preferred-username': 'dsaw',
    'x-forwarded-groups': allAccessGroups,
  });
  await page.goto('/keys');

  await expect(page.getByRole('heading', { name: 'Unlock keys and secrets' })).toBeVisible();
  await expect(page.locator('.vault-unlock').getByText(/second sign-in/)).toBeVisible();

  await page.getByLabel('Kanidm password for your account').fill('wrong-password');
  await page.getByRole('button', { name: 'Unlock' }).click();
  await expect(page.getByText('That password or code was not accepted.')).toBeVisible();

  await page.getByLabel('Kanidm password for your account').fill(vaultPassword);
  await page.getByRole('button', { name: 'Unlock' }).click();
  await expect(page.getByText('Unlocked.', { exact: false })).toBeVisible();
  await expect(page.getByText(/Locks in \d+ min/)).toBeVisible();

  await page.getByRole('button', { name: 'Lock now' }).click();
  await expect(page.getByRole('heading', { name: 'Unlock keys and secrets' })).toBeVisible();

  const secrets = await page.request.get('/api/vault/syncthing', { headers: identityHeaders('dsaw', allAccessGroups) });
  expect(secrets.status()).toBe(401);
});

test('accounts with TOTP get a second-step prompt', async ({ page }) => {
  await page.setExtraHTTPHeaders(identityHeaders('mfa', 'freshrss-users'));
  await page.goto('/keys');

  const startUnlock = async (password = vaultPassword) => {
    await page.getByLabel('Kanidm password for your account').fill(password);
    await page.getByRole('button', { name: 'Unlock' }).click();
    await expect(page.getByText('Enter the six-digit code from your authenticator app.')).toBeVisible();
  };

  await startUnlock();
  await page.getByLabel('Six-digit sign-in code').fill('000000');
  await page.getByRole('button', { name: 'Finish unlock' }).click();
  await expect(page.getByText('That password or code was not accepted.')).toBeVisible();

  await startUnlock('wrong-password');
  await page.getByLabel('Six-digit sign-in code').fill(totpCode);
  await page.getByRole('button', { name: 'Finish unlock' }).click();
  await expect(page.getByText('That password or code was not accepted.')).toBeVisible();

  await startUnlock();
  await page.getByLabel('Six-digit sign-in code').fill(totpCode);
  await page.getByRole('button', { name: 'Finish unlock' }).click();
  await expect(page.getByText('Unlocked.', { exact: false })).toBeVisible();
});

test('the SSH card lists and registers device keys', async ({ page, baseURL }) => {
  await unlockThroughApi(page, baseURL, 'dsaw', allAccessGroups);
  await page.goto('/keys');

  const sshCard = page.locator('article').filter({ has: page.getByRole('heading', { name: 'SSH public keys' }) });
  await expect(sshCard.getByRole('heading', { name: 'Registered device keys' })).toBeVisible();

  await sshCard.locator('#vault-ssh-public-key').fill(validPublicKey);
  await sshCard.getByRole('button', { name: 'Save Public Key' }).click();
  await expect(sshCard.getByText(/SFTP device key added and verified on the server./)).toBeVisible();
  await expect(sshCard.locator('li').filter({ hasText: 'laptop' })).toHaveCount(1);

  await sshCard.locator('#vault-ssh-public-key').fill(validPublicKey);
  await sshCard.getByRole('button', { name: 'Save Public Key' }).click();
  await expect(sshCard.getByText(/SFTP device key added and verified on the server./)).toBeVisible();
  await expect(sshCard.locator('li').filter({ hasText: 'laptop' })).toHaveCount(1);
});

test('the Syncthing card reveals and regenerates the server API key', async ({ page, baseURL }) => {
  await unlockThroughApi(page, baseURL, 'dsaw', allAccessGroups);
  await page.goto('/keys');

  const card = page.locator('article').filter({ has: page.getByRole('heading', { name: 'Syncthing API key' }) });
  await expect(card.locator('code').filter({ hasText: '••••' })).toBeVisible();

  await card.getByRole('button', { name: 'Reveal' }).click();
  const revealed = card.locator('code').filter({ hasText: /^[0-9a-f]{32,64}$/ });
  await expect(revealed).toBeVisible();
  const before = await revealed.textContent();

  await card.getByRole('button', { name: 'Regenerate API key' }).click();
  await expect(card.getByText('Yes, regenerate')).toBeVisible();
  await card.getByRole('button', { name: 'Yes, regenerate' }).click();
  await expect(revealed).toBeVisible();
  await expect.poll(async () => await revealed.textContent(), { timeout: 15_000 }).not.toBe(before);
});

test('the FreshRSS card registers an API password that is shown once', async ({ page, baseURL }) => {
  await unlockThroughApi(page, baseURL, 'dsaw', allAccessGroups);
  await page.goto('/keys');

  const card = page.locator('article').filter({ has: page.getByRole('heading', { name: 'FreshRSS API password' }) });
  await card.getByRole('button', { name: 'Register an API password' }).click();
  await expect(card.getByText(/Generate a new FreshRSS API password for/)).toBeVisible();
  await card.getByRole('button', { name: 'Yes, generate' }).click();

  await expect(card.getByText('Shown once.')).toBeVisible();
  const passwordCode = card.locator('.vault-once__fields div').filter({ hasText: 'API password' }).locator('code');
  await expect(passwordCode).toHaveText(/^[A-Za-z0-9]{32}$/);
  await expect(card.getByText('https://rss.example.test/api/greader.php')).toBeVisible();

  await card.getByRole('button', { name: 'Generate a new API password' }).click();
  await card.getByRole('button', { name: 'Yes, generate' }).click();
  const secondPassword = await passwordCode.textContent();
  expect(secondPassword).toMatch(/^[A-Za-z0-9]{32}$/);
});

test('the Kavita card creates, rotates, and deletes API keys', async ({ page, baseURL }) => {
  await unlockThroughApi(page, baseURL, 'dsaw', allAccessGroups);
  await page.goto('/keys');

  const card = page.locator('article').filter({ has: page.getByRole('heading', { name: 'Kavita API keys' }) });
  await expect(card.locator('.vault-kavita-key').filter({ hasText: 'opds' })).toBeVisible();

  await card.locator('#vault-kavita-name').fill('Tablet reader');
  await card.getByRole('button', { name: 'Create key' }).click();
  await expect(card.locator('.vault-kavita-key').filter({ hasText: 'Tablet reader' })).toBeVisible();

  const tabletKey = card.locator('.vault-kavita-key').filter({ hasText: 'Tablet reader' });
  await tabletKey.getByRole('button', { name: 'Reveal' }).click();
  await expect(tabletKey.locator('code').filter({ hasText: /^e2e/ })).toBeVisible();

  await tabletKey.getByRole('button', { name: 'Regenerate', exact: true }).click();
  await tabletKey.getByRole('button', { name: 'Confirm rotate' }).click();
  await expect(card.getByText('Key Tablet reader regenerated.')).toBeVisible();

  await tabletKey.getByRole('button', { name: 'Delete', exact: true }).click();
  await tabletKey.getByRole('button', { name: 'Confirm delete' }).click();
  await expect(card.getByText('Key Tablet reader deleted.')).toBeVisible();
  await expect(card.locator('.vault-kavita-key').filter({ hasText: 'Tablet reader' })).toHaveCount(0);
});

test('features outside the account permissions are listed as unavailable', async ({ page, baseURL }) => {
  await unlockThroughApi(page, baseURL, 'basic', 'users');
  await page.goto('/keys');

  await expect(page.getByRole('heading', { name: 'Not available to your account' })).toBeVisible();
  await expect(page.getByText('Syncthing API key')).toBeVisible();
  await expect(page.getByText('· administrators only')).toBeVisible();
  await expect(page.locator('article').filter({ has: page.getByRole('heading', { name: 'Syncthing API key' }) })).toHaveCount(0);

  const syncthing = await page.request.get('/api/vault/syncthing', { headers: identityHeaders('basic', 'users') });
  expect(syncthing.status()).toBe(403);
  const freshrss = await page.request.post('/api/vault/freshrss', { data: {}, headers: { ...identityHeaders('basic', 'users'), origin: baseURL, 'sec-fetch-site': 'same-origin' } });
  expect(freshrss.status()).toBe(403);
});

test('an expired vault session returns to the unlock form', async ({ page, baseURL }) => {
  await unlockThroughApi(page, baseURL, 'dsaw', allAccessGroups);
  await page.goto('/keys');
  await expect(page.getByText('Unlocked.', { exact: false })).toBeVisible();

  const cleared = await page.context().clearCookies();
  void cleared;
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Unlock keys and secrets' })).toBeVisible();
});
