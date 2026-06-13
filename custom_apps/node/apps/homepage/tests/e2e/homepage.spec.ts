import { expect, test } from '@playwright/test';

const validPublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDECtGBZcPahwDCtWiMgn24qGdqMOJhPpHoPpKsHAF laptop';

test.beforeEach(async ({ page }) => {
  page.on('pageerror', (error) => {
    throw error;
  });
});

test('homepage navigation and SFTP upload flow stay client-side', async ({ page }) => {
  await page.goto('/');

  await expect(page.getByRole('navigation', { name: 'Homepage sections' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Services' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'SFTP Access', exact: true })).toBeVisible();

  await page.getByRole('link', { name: 'Details' }).filter({ hasText: 'Details' }).first().click();
  await expect(page).toHaveURL(/\/services\/photos$/);
  await page.getByRole('link', { name: 'Services' }).click();

  await page.getByRole('link', { name: 'SFTP Access', exact: true }).click();
  await expect(page).toHaveURL(/\/uploads$/);
  await expect(page.getByRole('heading', { name: 'SSHFS Mount Setup' })).toBeVisible();

  const setup = page.locator('article').filter({ has: page.getByRole('heading', { name: 'SSHFS Mount Setup' }) });
  await expect(setup.locator('pre.windows code').first()).toBeVisible();
  await expect(setup.locator('pre.windows code').first()).toContainText('New-Item -ItemType Directory -Force');
  await expect(setup.locator('pre.windows code').first()).toContainText('ssh-keygen -t ed25519');
  await expect(setup.locator('pre.windows code').first()).toContainText('Get-Content $env:USERPROFILE');
  await expect(setup.getByText('Install WinFsp and SSHFS-Win')).toBeVisible();
  await expect(setup.getByText('Mount the same drive automatically when Windows starts')).toBeVisible();
  await expect(setup.locator('pre.windows code').nth(2)).toContainText('/persistent:yes');

  await setup.locator('label[for="sftp-setup-macos"]').click();
  await expect(setup.locator('pre.macos code').first()).toBeVisible();
  await expect(setup.locator('pre.macos code').first()).toContainText('mkdir -p ~/.ssh && chmod 700 ~/.ssh');
  await expect(setup.getByText('Install macFUSE and sshfs')).toBeVisible();
  await expect(setup.locator('pre.macos code').nth(2)).toContainText('LaunchAgents/org.nixhomeserver.sshfs.plist');

  await setup.locator('label[for="sftp-setup-linux"]').click();
  await expect(setup.getByText('Install sshfs, then mount the server manually')).toBeVisible();
  await expect(setup.locator('pre.linux code').nth(2)).toContainText('systemctl --user enable --now nixhomeserver-files.service');

  const uploadHeading = page.getByRole('heading', { name: 'Upload SSHFS Public Key' });
  await uploadHeading.scrollIntoViewIfNeeded();
  const beforeEmptySaveUrl = page.url();
  await page.getByRole('button', { name: 'Save Public Key' }).click();
  await expect(page).toHaveURL(beforeEmptySaveUrl);
  await expect(page.getByText('Paste one OpenSSH public key before saving.')).toBeVisible();

  await page.getByPlaceholder('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... laptop').fill(validPublicKey);
  await page.getByRole('button', { name: 'Save Public Key' }).click();
  await expect(page.getByText('SFTP public key saved and verified on the server.')).toBeVisible();
  await expect(page.getByText('owner=root:root mode=644')).toBeVisible();
});

test('top-level pages and profile menu render without full reloads', async ({ page }) => {
  await page.goto('/');

  await page.getByRole('link', { name: 'Getting Started' }).click();
  await expect(page).toHaveURL(/\/getting-started$/);
  await expect(page.getByRole('heading', { name: 'Connect Your Devices' })).toBeVisible();

  await page.getByRole('link', { name: 'For Admins' }).click();
  await expect(page).toHaveURL(/\/admins$/);
  await expect(page.getByRole('heading', { name: 'Server Bootstrap' })).toBeVisible();

  await page.getByRole('link', { name: 'How to Upload Files' }).click();
  await expect(page).toHaveURL(/\/uploads$/);
  await page.getByRole('link', { name: 'Audiobooks' }).click();
  await expect(page).toHaveURL(/\/uploads\?guide=audiobooks$/);
  await expect(page.getByRole('heading', { name: 'Audiobooks' })).toBeVisible();

  await page.locator('summary.profile-trigger').click();
  await expect(page.getByRole('heading', { name: 'dsaw' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Sign out' })).toBeVisible();
});

test('shared top navigation works on all top-level pages and unknown service routes', async ({ page }) => {
  await page.goto('/');

  await page.getByRole('link', { name: 'Getting Started' }).click();
  await expect(page).toHaveURL(/\/getting-started$/);
  await expect(page.getByRole('navigation', { name: 'Homepage sections' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Getting Started' })).toHaveClass(/selected/);

  await page.getByRole('link', { name: 'How to Upload Files' }).click();
  await expect(page).toHaveURL(/\/uploads$/);
  await expect(page.getByRole('link', { name: 'How to Upload Files' })).toHaveClass(/selected/);

  await page.getByRole('link', { name: 'For Admins' }).click();
  await expect(page).toHaveURL(/\/admins$/);
  await expect(page.getByRole('link', { name: 'For Admins' })).toHaveClass(/selected/);

  await page.getByRole('link', { name: 'Services' }).click();
  await expect(page).toHaveURL('/');
  await expect(page.getByRole('link', { name: 'Services' })).toHaveClass(/selected/);

  await page.goto('/services/does-not-exist');
  await expect(page.getByRole('heading', { name: 'Service Not Found' })).toBeVisible();
  await page.getByRole('link', { name: 'Back to services' }).click();
  await expect(page).toHaveURL('/');
  await expect(page.getByRole('heading', { name: 'Services' })).toBeVisible();
});
