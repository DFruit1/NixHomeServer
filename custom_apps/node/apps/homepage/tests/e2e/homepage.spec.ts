import { expect, test, type Page } from '@playwright/test';

const validPublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDECtGBZcPahwDCtWiMgn24qGdqMOJhPpHoPpKsHAF laptop';

const expectNoHorizontalOverflow = async (page: Page) => {
  await expect
    .poll(() =>
      page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth),
    )
    .toBeLessThanOrEqual(1);
};

test.beforeEach(async ({ page }) => {
  page.on('pageerror', (error) => {
    throw error;
  });
});

test('all locally mapped service icons are packaged and renderable', async ({ page }) => {
  for (const icon of [
    'immich',
    'paperless-ngx',
    'filestash',
    'audiobookshelf',
    'jellyfin',
    'kavita',
    'vaultwarden',
    'mail-archive-ui',
    'sonarr',
    'radarr',
    'prowlarr',
    'qbittorrent',
    'syncthing',
    'kiwix',
    'youtube',
    'kopia',
    'beszel',
  ]) {
    const response = await page.request.get(`/logos/${icon}.svg`);
    expect(response.ok(), `${icon} icon should be packaged`).toBeTruthy();
    expect(response.headers()['content-type']).toContain('image/svg+xml');
  }

  await page.setExtraHTTPHeaders({
    'x-forwarded-groups': 'users backup-admin files-personal-users jellyfin-users photos-users',
  });
  await page.goto('/');
  for (const service of ['photos', 'files', 'videos', 'backups']) {
    await expect(page.locator(`.app-symbol--${service} img`)).toBeVisible();
  }
  await expect(page.locator('.app-symbol--backups img')).toBeVisible();
  await expect(page.locator('.app-symbol--backups')).not.toHaveText('L');
});

test('offline media connection help renders the configured network labels', async ({ page }) => {
  await page.setExtraHTTPHeaders({
    'x-forwarded-groups': 'users',
  });
  await page.route('**/api/mkvmaker/progress', async (route) => {
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        enabled: true,
        available: true,
        state: 'converting',
        conversions: [{
          title: 'Example Movie',
          mediaKind: 'movie',
          itemName: 'Example Movie.mkv',
          itemIndex: 1,
          itemCount: 1,
          percent: 42.5,
          itemPercent: 42.5,
          etaSeconds: 900,
          rateFps: 58.2,
        }],
      }),
    });
  });
  await page.goto('/services/offline-media');

  await expect(page.getByText('Automatically keep copies of your server music and videos on a computer or phone.', { exact: true })).toBeVisible();
  await expect(page.locator('.service-detail-heading .app-symbol--offline-media img')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'DVD conversion progress' })).toBeVisible();
  await expect(page.getByText('Example Movie', { exact: true })).toBeVisible();
  await expect(page.getByRole('progressbar', { name: 'Example Movie 42.5% converted' })).toHaveAttribute('value', '42.5');
  await expect(page.getByText('ETA 15 min · 58.2 fps', { exact: true })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Set up Syncthing-Fork' })).toBeVisible();
  await expect(page.getByText('Syncthing-Fork is the supported app.')).toBeVisible();
  await expect(page.getByText('iPhone and iPad are not supported.')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Connection status' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Keep media on your device' })).toHaveCount(0);
  await expect(page.getByText(/Möbius Sync/)).toHaveCount(0);
  const offlineMediaLayout = page.locator('.offline-media-layout');
  await expect(offlineMediaLayout).toHaveCSS('display', 'grid');
  await expect.poll(() => offlineMediaLayout.evaluate((element) => getComputedStyle(element).gridTemplateColumns.split(' ').length))
    .toBe((page.viewportSize()?.width ?? 1280) <= 760 ? 1 : 2);
  await page.locator('summary').filter({ hasText: 'Connection help' }).click();
  await expect(page.getByRole('heading', { name: 'Recommended server address' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'At home (LAN)' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Away from home (NetBird)' })).toBeVisible();
  await expect(page.getByText('tcp://server.internal:22000', { exact: true })).toBeVisible();
  await expect(page.getByText('tcp://192.168.8.12:22000', { exact: true })).toBeVisible();
  await expect(page.getByText('tcp://100.72.113.237:22000', { exact: true })).toBeVisible();
});

test('homepage navigation and SFTP upload flow stay client-side', async ({ page }) => {
  await page.setExtraHTTPHeaders({
    'x-forwarded-groups': 'users photos-users files-personal-users files-sftp-users',
  });
  await page.goto('/');

  await expect(page).toHaveTitle('Example Home Services');
  const topNavigation = page.getByRole('navigation', { name: 'Homepage sections' });
  await expect(topNavigation).toBeVisible();
  await expect(topNavigation.getByRole('link')).toHaveText([
    'Services',
    'Getting Started',
    'Detailed Guide',
    'For Admins',
  ]);
  await expect(page.getByRole('region', { name: 'Services' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'SFTP Access', exact: true })).toHaveCount(0);

  await page.getByRole('button', { name: 'Photos service information' }).click();
  await expect(page).toHaveURL(/\/$/);
  await expect(page.locator('.service-preview-bar')).toHaveClass(/open/);
  await expect(page.locator('.service-preview-bar')).toContainText('Photo and video library with private login and public share-link support.');
  await expect(page.locator('.service-preview-bar').getByRole('link', { name: 'Open', exact: true })).toHaveAttribute('target', '_blank');
  await expect(page.locator('.service-preview-bar').getByRole('link', { name: 'Project Homepage' })).toHaveAttribute('target', '_blank');
  await expect(page.getByRole('button', { name: 'Photos service information' })).toHaveAttribute('aria-pressed', 'true');
  await page.getByRole('button', { name: 'Photos service information' }).click();
  await expect(page.locator('.service-preview-bar')).not.toHaveClass(/open/);

  await page.getByRole('link', { name: 'Detailed Guide' }).click();
  await expect(page).toHaveURL(/\/uploads$/);
  await expect(page.getByRole('heading', { name: 'Detailed Guide' })).toBeVisible();
  await page.getByRole('link', { name: 'SSHFS Mount' }).click();
  await expect(page).toHaveURL(/\/uploads\?guide=sshfs#guide-detail$/);
  await expect(page.getByRole('heading', { name: 'SSHFS Mount' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Upload SSHFS Public Key' })).toHaveCount(0);
  await page.getByRole('link', { name: 'Set up SSHFS in Getting Started' }).click();
  await expect(page).toHaveURL(/\/getting-started\?step=uploads#sshfs-setup$/);
  await expect(page.getByRole('heading', { name: 'SSHFS Mount Setup' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Read the detailed SSHFS guide' })).toHaveAttribute('href', '/uploads?guide=sshfs#guide-detail');
  await expect(page.getByText('Your account can also upload through https://files.example.test')).toBeVisible();
  await expectNoHorizontalOverflow(page);

  const setup = page.locator('article').filter({ has: page.getByRole('heading', { name: 'SSHFS Mount Setup' }) });
  // The OS tabs default to the detected operating system (Linux in the test runner).
  await expect(setup.locator('pre.linux code').first()).toBeVisible();
  await expect(setup.getByText('Install sshfs, then mount the server manually')).toBeVisible();
  await expect(setup.locator('pre code').filter({ hasText: 'systemctl --user enable --now nixhomeserver-files.service' })).toBeVisible();
  await expect(setup.locator('label[for="sftp-setup-linux-systemd"]')).toBeChecked();

  await setup.locator('label[for="sftp-setup-linux-runit"]').click();
  await expect(setup.locator('pre code').filter({ hasText: 'xbps-install -S turnstile' })).toBeVisible();
  await expect(setup.locator('pre code').filter({ hasText: 'SVDIR=~/.config/service sv up nixhomeserver-files' })).toBeVisible();
  await setup.locator('label[for="sftp-setup-linux-systemd"]').click();

  await setup.locator('label[for="sftp-setup-windows"]').click();
  await expect(setup.locator('pre.windows code').first()).toBeVisible();
  await expect(setup.locator('pre.windows code').first()).toContainText('New-Item -ItemType Directory -Force');
  await expect(setup.locator('pre.windows code').first()).toContainText('ssh-keygen -t rsa -b 4096');
  await expect(setup.locator('pre.windows code').first()).toContainText('Get-Content $env:USERPROFILE');
  await expect(setup.getByText('Install WinFsp and SSHFS-Win before mounting the server.')).toBeVisible();
  await expect(setup.getByText('Mount the same drive automatically when Windows starts')).toBeVisible();
  await expect(setup.locator('pre code').filter({ hasText: '/persistent:yes' })).toBeVisible();
  await expect(setup.locator('pre code').filter({ hasText: '!2022' }).first()).toBeVisible();

  await setup.locator('label[for="sftp-setup-macos"]').click();
  await expect(setup.locator('pre.macos code').first()).toBeVisible();
  await expect(setup.locator('pre.macos code').first()).toContainText('mkdir -p ~/.ssh && chmod 700 ~/.ssh');
  await expect(setup.getByText('Install macFUSE and sshfs before mounting the server.')).toBeVisible();
  await expect(setup.locator('pre code').filter({ hasText: 'LaunchAgents/org.nixhomeserver.sshfs.plist' })).toBeVisible();

  await setup.locator('label[for="sftp-setup-linux"]').click();
  await expect(setup.getByText('Install sshfs, then mount the server manually')).toBeVisible();
  await expect(setup.locator('pre code').filter({ hasText: 'systemctl --user enable --now nixhomeserver-files.service' })).toBeVisible();
  await expect(setup.locator('label[for="sftp-setup-linux-systemd"]')).toBeChecked();

  const uploadHeading = page.getByRole('heading', { name: 'Upload SSHFS Public Key' });
  await uploadHeading.scrollIntoViewIfNeeded();
  const savePublicKeyButton = page.getByRole('button', { name: 'Save Public Key' });
  await savePublicKeyButton.scrollIntoViewIfNeeded();
  const beforeEmptySaveUrl = page.url();
  await savePublicKeyButton.click({ force: true });
  await expect(page).toHaveURL(beforeEmptySaveUrl);
  await expect(page.getByText('Paste one OpenSSH public key before saving.')).toBeVisible();

  await page.getByPlaceholder('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... laptop').fill(validPublicKey);
  await savePublicKeyButton.click({ force: true });
  await expect(page.getByText('SFTP device key added and verified on the server.')).toBeVisible();
  await expect(page.getByText('owner=root:root mode=644')).toBeVisible();
});

test('SFTP-only users are not told that browser uploads are available', async ({ page }) => {
  await page.setExtraHTTPHeaders({
    'x-forwarded-preferred-username': 'sftp-only',
    'x-forwarded-groups': 'users files-sftp-users',
  });
  await page.goto('/uploads?guide=sshfs');

  await expect(page.getByRole('heading', { name: 'SSHFS Mount' })).toBeVisible();
  await expect(page.getByText('SFTP/SSHFS and browser Files access use separate permissions.')).toBeVisible();
  await expect(page.getByText('Browser Files is not currently available to your account.')).toBeVisible();
  await expect(page.getByText(/Your account can also upload through/)).toHaveCount(0);
});

for (const role of [
  { role: 'shared-only', group: 'files-shared-users', visiblePath: '/_Shared' },
  { role: 'USB-only', group: 'usb-access', visiblePath: '/_USB' },
  { role: 'backup-storage-only', group: 'backup-storage-users', visiblePath: '/_Backups' },
]) {
  test(`${role.role} users receive role-specific SFTP guidance without browser Files access`, async ({ page }) => {
    await page.setExtraHTTPHeaders({
      'x-forwarded-preferred-username': role.role,
      'x-forwarded-groups': role.group,
    });
    await page.goto('/uploads?guide=sshfs');

    await expect(page.getByRole('heading', { name: 'SSHFS Mount' })).toBeVisible();
    await expect(page.getByText(role.visiblePath, { exact: false })).toBeVisible();
    await expect(page.locator('.guide-callout').filter({ hasText: 'Your SFTP root includes' })).toHaveCount(1);
    await expect(page.getByText('Browser Files is not currently available to your account.')).toBeVisible();
    await expect(page.getByText(/Your account can also upload through/)).toHaveCount(0);
  });
}

test('top-level pages and profile menu render without full reloads', async ({ page }) => {
  await page.setExtraHTTPHeaders({
    'x-forwarded-groups': 'users backup-admin files-personal-users jellyfin-users photos-users',
  });
  await page.goto('/');

  await page.getByRole('link', { name: 'Getting Started' }).click();
  await expect(page).toHaveURL(/\/getting-started$/);
  await expect(page).toHaveTitle('Getting Started | Example Home Services');
  await expect(page.locator('.getting-started-header')).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'Install a password manager' })).toBeVisible();
  const setupNavigation = page.getByRole('navigation', { name: 'Getting started steps' });
  await expect(setupNavigation.locator('details')).toHaveCount(0);
  await expect(setupNavigation.locator('.step-number')).toHaveCount(0);
  await expect(setupNavigation.locator('small')).toHaveCount(0);
  for (const step of [
    'Install a password manager',
    'Activate your account',
    'Save recovery details',
    'Open your services',
    'Add your files',
    'Set up access away from home',
    'Connect optional apps',
  ]) {
    await expect(setupNavigation.getByRole('link', { name: step, exact: true })).toBeVisible();
  }
  await expect(page.getByRole('link', { name: 'Download Bitwarden' })).toHaveAttribute('href', 'https://bitwarden.com/download/');
  await expect(page.getByRole('link', { name: 'Download KeePassXC' })).toHaveAttribute('href', 'https://keepassxc.org/download/');
  await expect(page.getByText(/Immich|Jellyfin|Inkita|Lissen|Audiobookshelf/)).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'Apps available to you' })).toHaveCount(0);
  await expect(page.getByText('Photo and video library with private login and public share-link support.')).toHaveCount(0);
  await expect(page.getByLabel('Install a password manager on a trusted device')).toBeVisible();
  await page.getByLabel('Install a password manager on a trusted device').check();
  await page.locator('.step-pagination').getByRole('link', { name: 'Activate your account' }).click();
  await expect(page).toHaveURL(/\/getting-started\?step=account#guide$/);
  await expect(page.getByRole('heading', { name: 'Activate your account' })).toBeVisible();
  await expect(page.getByText('Signed in as dsaw', { exact: false })).toBeVisible();
  await expect(page.getByText(/progress is saved only in this browser profile/)).toBeVisible();
  await expect(page.getByText(/It works once and expires after one hour/)).toBeVisible();
  await expect(page.getByText('Use a trusted network path.')).toBeVisible();
  await expect(page.getByText(/Never send an admin your password/)).toBeVisible();
  await expect(page.getByRole('link', { name: 'Open Kanidm' })).toHaveAttribute('target', '_blank');

  await page.getByLabel('Confirm your name and email in Kanidm').check();
  await expect(page.getByLabel('Confirm your name and email in Kanidm')).toBeChecked();

  await setupNavigation.getByRole('link', { name: 'Save recovery details' }).click();
  await expect(page).toHaveURL(/\/getting-started\?step=recovery#guide$/);
  await expect(page.getByText('The Passwords app is not available to you.')).toBeVisible();
  await expect(page.getByLabel('Save your Kanidm username and sign-in address in your password manager')).toBeVisible();
  await expect(page.getByText('Keep a recovery copy outside this server', { exact: true })).toHaveCount(0);
  await expect(page.getByText('Kanidm sign-in', { exact: true })).toBeVisible();
  await expect(page.getByText('Videos password', { exact: true })).toHaveCount(0);
  await expect(page.getByText('Local Backups password', { exact: true })).toBeVisible();

  await setupNavigation.getByRole('link', { name: 'Open your services' }).click();
  await expect(page).toHaveURL(/\/getting-started\?step=services#guide$/);
  await expect(page.getByRole('heading', { name: 'Open your services' })).toBeVisible();
  await expect(page.getByText(/lists 5 apps assigned to your account/)).toBeVisible();
  await expect(page.getByLabel('Available services').getByText('Local Backups')).toBeVisible();
  await expect(page.getByLabel('Available services').getByText('Passwords')).toHaveCount(0);
  await expect(page.getByLabel('Open Local Backups and sign in with the Kopia password from an admin')).toBeVisible();
  await expect(page.getByText(/Jellyfin password/)).toHaveCount(0);
  await expect(page.getByText('Local Backups has two sign-in gates.')).toBeVisible();
  await expect(page.getByText('If access was just changed, refresh your sign-in first.')).toBeVisible();

  await setupNavigation.getByRole('link', { name: 'Add your files' }).click();
  await expect(page).toHaveURL(/\/getting-started\?step=uploads#guide$/);
  await expect(page.getByRole('heading', { name: 'Add your files' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Open Files' })).toHaveAttribute('target', '_blank');
  await expect(page.getByText(/Browser Files and SFTP\/SSHFS are separate permissions/)).toBeVisible();

  await setupNavigation.getByRole('link', { name: 'Set up access away from home' }).click();
  await expect(page.getByRole('link', { name: 'Download NetBird' })).toHaveAttribute('href', 'https://docs.netbird.io/get-started/install');

  await setupNavigation.getByRole('link', { name: 'Connect optional apps' }).click();
  await expect(page.getByRole('heading', { name: 'Connect optional apps' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Download Immich' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Download Jellyfin' })).toBeVisible();
  await expect(page.getByText(/Inkita, Lissen, and Audiobookshelf/)).toBeVisible();
  await expect(page.getByText(/ask an admin for the initial Jellyfin password/)).toBeVisible();

  await page.getByRole('link', { name: 'For Admins' }).click();
  await expect(page).toHaveURL(/\/admins$/);
  await expect(page.getByRole('heading', { name: 'Admin tools' })).toBeVisible();
  await expect(page.getByText(/These commands can change the live server/)).toBeVisible();
  await expect(page.getByPlaceholder(/Search commands/)).toBeVisible();

  await expect(page.getByText('Validate config & prerequisites')).toBeVisible();
  await expect(page.getByText('Test deploy')).toBeVisible();
  await expect(page.getByText('Failed services')).toBeVisible();
  await expect(page.getByText('Verify user exists')).toBeVisible();
  await expect(page.getByText('Check space & disks')).toBeVisible();
  await expect(page.getByText('Reverse proxy health')).toBeVisible();

  for (const title of ['Validate config & prerequisites', 'Test deploy', 'Reverse proxy health']) {
    await page.locator('details.admin-task').filter({ hasText: title }).locator('summary').click();
  }
  await expect(page.getByText('nix run .#validate-config-readiness')).toBeVisible();
  await expect(page.getByText('./scripts/deploy.sh --action test')).toBeVisible();
  await expect(page.getByText('systemctl status caddy.service --no-pager')).toBeVisible();

  await page.getByPlaceholder(/Search commands/).fill('snapshot');
  await expect(page.getByText('Backup schedule')).toBeVisible();
  await expect(page.getByText('Trigger snapshot now')).toBeVisible();
  await expect(page.getByText('Test deploy')).toHaveCount(0);

  await page.getByPlaceholder(/Search commands/).fill('kanidm');
  await expect(page.getByText('Verify user exists')).toBeVisible();
  await expect(page.getByText('Create user', { exact: true })).toBeVisible();
  await expect(page.getByText('Grant app access')).toBeVisible();
  await expect(page.getByText('Revoke access')).toBeVisible();
  await expect(page.getByText('Generate sign-in link')).toBeVisible();

  await page.getByPlaceholder(/Search commands/).fill('nonexistent');
  await expect(page.getByText('No commands match your search.')).toBeVisible();

  await page.getByRole('link', { name: 'Detailed Guide' }).click();
  await expect(page).toHaveURL(/\/uploads$/);
  await page.getByRole('link', { name: 'Audiobooks', exact: true }).click();
  await expect(page).toHaveURL(/\/uploads\?guide=folder-audiobooks#guide-detail$/);
  await expect(page.getByRole('heading', { name: 'Audiobooks' })).toBeVisible();

  await page.locator('summary.profile-trigger').click();
  await expect(page.getByRole('heading', { name: 'dsaw' })).toBeVisible();
  await expect(page.getByLabel('Show unused apps in Services')).not.toBeChecked();
  await expect(page.getByLabel('Show unused apps in Detailed Guide')).not.toBeChecked();
  await expect(page.getByRole('link', { name: 'Sign out' })).toBeVisible();
});

test('non-admin users cannot retrieve or render the admin handbook', async ({ page }) => {
  await page.setExtraHTTPHeaders({
    'x-forwarded-preferred-username': 'bob',
    'x-forwarded-groups': 'users',
  });

  const response = await page.goto('/admins');
  expect(response?.status()).toBe(403);
  await expect(page.getByRole('heading', { name: 'Administrator access required' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'For Admins' })).toHaveCount(0);
  await expect(page.getByText('nix run .#validate-config-readiness')).toHaveCount(0);

  const home = await page.request.get('/api/home', {
    headers: {
      'x-forwarded-preferred-username': 'bob',
      'x-forwarded-groups': 'users',
    },
  });
  expect(home.ok()).toBeTruthy();
  const data = await home.json();
  expect(data.isAdmin).toBe(false);
  expect(data.adminGuide).toEqual([]);
  expect(data.kanidmGroups).toBeUndefined();
});

test('getting started skips app and upload tasks that are unavailable to the account', async ({ page }) => {
  await page.setExtraHTTPHeaders({
    'x-forwarded-preferred-username': 'no-apps',
    'x-forwarded-groups': '',
  });

  await page.goto('/getting-started?step=services');
  await expect(page.getByText(/lists 0 apps assigned to your account/)).toBeVisible();
  await expect(page.getByText('No enabled apps are currently assigned to this account')).toBeVisible();
  await expect(page.getByLabel(/Open .* and complete its first-time sign-in/)).toHaveCount(0);
  await expect(page.locator('.getting-started-step').getByLabel('Skip (not available for this account)')).toBeVisible();

  await page.getByRole('navigation', { name: 'Getting started steps' }).getByRole('link', { name: 'Connect optional apps' }).click();
  await expect(page.getByRole('heading', { name: 'Connect optional apps' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Open Detailed Guide' })).toHaveCount(0);
  await expect(page.locator('.finish-next-steps').getByText('Detailed Guide')).toHaveCount(0);
});

test('detailed guide provides a hierarchical index and independently reveals unused apps', async ({ page }) => {
  await page.setExtraHTTPHeaders({
    'x-forwarded-groups': 'users backup-admin files-personal-users files-sftp-users jellyfin-users photos-users',
  });
  await page.goto('/uploads');

  const contents = page.getByRole('navigation', { name: 'Detailed guide contents' });
  await expect(contents.getByRole('heading', { name: 'Contents' })).toBeVisible();
  for (const topic of ['Overview', 'Photos', 'Files', 'Videos', 'Offline Media', 'Local Backups', 'SSHFS Mount', 'Documents', 'Audiobooks']) {
    await expect(contents.getByRole('link', { name: topic, exact: true })).toBeVisible();
  }
  await expect(contents.getByRole('link', { name: 'Passwords', exact: true })).toHaveCount(0);
  await expect(contents.getByText('Enabled', { exact: true })).toHaveCount(0);
  await expect(contents.getByText('Not enabled', { exact: true })).toHaveCount(0);

  const layout = page.locator('.detailed-guide-layout');
  const contentsWidth = await contents.evaluate((element) => element.getBoundingClientRect().width);
  const layoutWidth = await layout.evaluate((element) => element.getBoundingClientRect().width);
  if ((page.viewportSize()?.width ?? 1280) <= 760) {
    expect(contentsWidth / layoutWidth).toBeGreaterThan(0.95);
  } else {
    expect(contentsWidth / layoutWidth).toBeGreaterThan(0.27);
    expect(contentsWidth / layoutWidth).toBeLessThan(0.39);
  }

  await contents.getByRole('link', { name: 'Photos', exact: true }).click();
  await expect(page).toHaveURL(/\/uploads\?guide=service-photos#guide-detail$/);
  await expect(page.getByRole('heading', { name: 'Photos' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'What it is for' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'How to use it well' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'If something goes wrong' })).toBeVisible();

  await page.locator('summary.profile-trigger').click();
  await page.getByLabel('Show unused apps in Detailed Guide').check();
  await expect(contents.getByRole('link', { name: 'Passwords', exact: true })).toBeVisible();

  await page.getByRole('link', { name: 'Services', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Passwords is not active' })).toHaveCount(0);
  await page.locator('summary.profile-trigger').click();
  await page.getByLabel('Show unused apps in Services').check();
  await expect(page.getByRole('button', { name: 'Passwords is not active' })).toBeVisible();
});

test('unused SSHFS guidance hides connection details from accounts without SSHFS access', async ({ page }) => {
  await page.setExtraHTTPHeaders({
    'x-forwarded-preferred-username': 'no-file-access',
    'x-forwarded-groups': 'users',
  });
  await page.goto('/uploads');

  await page.locator('summary.profile-trigger').click();
  await page.getByLabel('Show unused apps in Detailed Guide').check();
  await page.getByRole('navigation', { name: 'Detailed guide contents' }).getByRole('link', { name: 'SSHFS Mount' }).click();

  await expect(page.getByText('Your account does not currently have SSHFS access.')).toBeVisible();
  await expect(page.getByText('server.home.arpa:2022', { exact: true })).toHaveCount(0);
  await expect(page.getByRole('link', { name: 'Set up SSHFS in Getting Started' })).toHaveCount(0);
});

test('shared top navigation works on all top-level pages and unknown service routes', async ({ page }) => {
  await page.goto('/');

  await page.getByRole('link', { name: 'Getting Started' }).click();
  await expect(page).toHaveURL(/\/getting-started$/);
  await expect(page.getByRole('navigation', { name: 'Homepage sections' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Getting Started' })).toHaveClass(/selected/);

  await page.getByRole('link', { name: 'Detailed Guide' }).click();
  await expect(page).toHaveURL(/\/uploads$/);
  await expect(page.getByRole('link', { name: 'Detailed Guide' })).toHaveClass(/selected/);

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
  await expect(page.getByRole('region', { name: 'Services' })).toBeVisible();
});
