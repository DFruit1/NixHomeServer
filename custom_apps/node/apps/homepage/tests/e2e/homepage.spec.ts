import { expect, test, type Page } from '@playwright/test';

const validPublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDECtGBZcPahwDCtWiMgn24qGdqMOJhPpHoPpKsHAF laptop';

const expectNoHorizontalOverflow = async (page: Page) => {
  await expect
    .poll(() =>
      page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth),
    )
    .toBeLessThanOrEqual(1);
};

/** The header of a Getting Started step, which opens and closes it. */
const stepHeader = (page: Page, name: string) => page.locator('.start-step__head').getByRole('button', { name });

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
    'chaptarr',
    'vaultwarden',
    'mail-archive-ui',
    'sonarr',
    'radarr',
    'prowlarr',
    'qbittorrent',
    'filesync',
    'kiwix',
    'youtube',
    'kopia',
    'archives',
    'search',
    'bonsai',
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

test('offline media page explains File Sync setup without device enrollment', async ({ page }) => {
  await page.setExtraHTTPHeaders({'x-forwarded-groups':'users files-personal-users'});
  await page.goto('/services/offline-media');
  await expect(page.getByRole('heading', {name:'Set up File Sync'})).toBeVisible();
  await expect(page.getByRole('link', {name:'Add the app repository'})).toBeVisible();
  await expect(page.getByLabel('Your device ID')).toHaveCount(0);
  await expectNoHorizontalOverflow(page);
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
    'Keys & Secrets',
    'Dashboard',
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

  // Getting Started hands the SSHFS setup over to the Detailed Guide, which owns it.
  await page.goto('/getting-started?step=files');
  await page.getByRole('link', { name: 'Set up SSHFS' }).click();
  await expect(page).toHaveURL(/\/uploads\?guide=sshfs$/);
  await expect(page.getByRole('heading', { name: 'Mount your files as a drive' })).toBeVisible();

  await page.getByRole('link', { name: 'All topics' }).click();
  await expect(page).toHaveURL(/\/uploads$/);
  await expect(page.getByRole('heading', { name: 'Detailed Guide' })).toBeVisible();
  await page.getByRole('link', { name: /^Mount your files as a drive/ }).click();
  await expect(page).toHaveURL(/\/uploads\?guide=sshfs$/);
  await expect(page.getByRole('heading', { name: 'Upload SSHFS Public Key' })).toBeVisible();
  await expect(page.getByText('server.home.arpa:2022', { exact: true })).toBeVisible();
  await expect(page.getByText('Your account can also upload through https://files.example.test')).toBeVisible();
  await expectNoHorizontalOverflow(page);

  const setup = page.locator('#sshfs-setup');
  // The OS tabs default to the detected operating system (Linux in the test runner).
  await expect(setup.locator('pre.linux code').first()).toBeVisible();
  await expect(setup.getByText('Install sshfs, then mount the server manually')).toBeVisible();
  // Automatic mounting is optional, so it stays collapsed until asked for.
  await expect(setup.locator('pre code').filter({ hasText: 'systemctl --user enable --now nixhomeserver-files.service' })).toBeHidden();
  await setup.locator('div.os-panel.linux details.auto-mount > summary').click();
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
  await setup.locator('div.os-panel.windows details.auto-mount > summary').click();
  await expect(setup.getByText('Mount the same drive automatically when Windows starts')).toBeVisible();
  await expect(setup.locator('pre code').filter({ hasText: '/persistent:yes' })).toBeVisible();
  await expect(setup.locator('pre code').filter({ hasText: '!2022' }).first()).toBeVisible();

  await setup.locator('label[for="sftp-setup-macos"]').click();
  await expect(setup.locator('pre.macos code').first()).toBeVisible();
  await expect(setup.locator('pre.macos code').first()).toContainText('mkdir -p ~/.ssh && chmod 700 ~/.ssh');
  await expect(setup.getByText('Install macFUSE and sshfs before mounting the server.')).toBeVisible();
  await setup.locator('div.os-panel.macos details.auto-mount > summary').click();
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

  await expect(page.getByRole('heading', { name: 'Mount your files as a drive' })).toBeVisible();
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

    await expect(page.getByRole('heading', { name: 'Mount your files as a drive' })).toBeVisible();
    await expect(page.getByText(role.visiblePath, { exact: false })).toBeVisible();
    await expect(page.locator('.sshfs-access-notes li').filter({ hasText: 'Your SFTP root includes' })).toHaveCount(1);
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
  await expect(page.getByText(/Progress stays in this browser/)).toBeVisible();
  for (const step of [
    'Install a password manager',
    'Protect your sign-in',
    'Open your apps',
    'Add your files',
    'Set up your phone and TV',
    'Use it away from home',
  ]) {
    await expect(stepHeader(page, step)).toBeVisible();
  }

  // One step is open at a time; the others keep their content out of the way.
  await expect(page.locator('#step-passwords-body')).toBeVisible();
  await expect(page.locator('#step-phone-body')).toBeHidden();
  await expect(page.getByRole('link', { name: 'Get Bitwarden' })).toHaveAttribute('href', 'https://bitwarden.com/download/');
  await expect(page.getByRole('link', { name: 'Get KeePassXC' })).toHaveAttribute('href', 'https://keepassxc.org/download/');

  await page.getByRole('button', { name: 'Done & continue' }).click();
  await expect(page.locator('#step-passwords')).toHaveClass(/is-done/);
  await expect(page.locator('#step-passwords-body')).toBeHidden();
  await expect(page.locator('#step-account-body')).toBeVisible();
  await expect(page.getByText('You are signed in as dsaw', { exact: false })).toBeVisible();
  await expect(page.getByText(/works once and expires after an hour/)).toBeVisible();
  await expect(page.getByText(/Never send an admin your password/)).toBeVisible();
  await expect(page.getByRole('link', { name: 'Open Kanidm' })).toHaveAttribute('target', '_blank');

  // Progress survives a reload and the page resumes at the first step still to do.
  await page.reload();
  await expect(page.locator('#step-passwords')).toHaveClass(/is-done/);
  await expect(page.locator('#step-account-body')).toBeVisible();
  await stepHeader(page, 'Install a password manager').click();
  await page.getByRole('button', { name: 'Mark as not done' }).click();
  await expect(page.locator('#step-passwords')).not.toHaveClass(/is-done/);

  await stepHeader(page, 'Open your apps').click();
  await expect(page.getByText(/5 apps are assigned to your account/)).toBeVisible();
  const apps = page.getByLabel('Your apps');
  await expect(apps.getByText('Local Backups')).toBeVisible();
  await expect(apps.getByText('Passwords')).toHaveCount(0);
  await expect(apps.getByText(/Asks for a second password after you sign in/)).toBeVisible();
  await expect(apps.getByRole('link', { name: 'Open Photos' })).toHaveAttribute('target', '_blank');
  await expect(apps.getByRole('link', { name: 'Photos guide' })).toHaveAttribute('href', '/uploads?guide=service-photos');
  await expect(page.getByText('Use a trusted network path.')).toBeVisible();
  // Shared troubleshooting has one home in the guide.
  await expect(page.getByRole('link', { name: 'App not opening? Try these checks.' })).toHaveAttribute('href', '/uploads?guide=help');

  // Links written for the old step names still open the matching step.
  await page.goto('/getting-started?step=uploads');
  await expect(page.locator('#step-files-body')).toBeVisible();
  await expect(page.getByRole('link', { name: 'Open Files' })).toHaveAttribute('target', '_blank');
  await expect(page.getByText(/Browser Files and SFTP\/SSHFS are separate permissions/)).toBeVisible();
  await expect(page.locator('.folder-map').getByText('/_Audiobooks', { exact: true })).toBeVisible();

  await stepHeader(page, 'Use it away from home').click();
  await expect(page.getByRole('link', { name: 'Get NetBird' })).toHaveAttribute('href', 'https://docs.netbird.io/get-started/install');

  await stepHeader(page, 'Set up your phone and TV').click();
  await page.locator('summary').filter({ hasText: 'Back up phone photos with Immich' }).click();
  await expect(page.getByRole('link', { name: 'Get Immich' })).toBeVisible();
  await page.locator('summary').filter({ hasText: 'Watch on a phone or TV with Jellyfin' }).click();
  await expect(page.getByRole('link', { name: 'Get Jellyfin' })).toBeVisible();
  await expect(page.getByText(/ask an admin for the initial Jellyfin password/)).toBeVisible();
  await expect(page.getByRole('link', { name: 'Approve a Quick Connect code' }))
    .toHaveAttribute('href', 'https://videos.example.test/sso/OIDC/QuickConnect/kanidm');
  await expectNoHorizontalOverflow(page);

  await page.getByRole('link', { name: 'For Admins' }).click();
  await expect(page).toHaveURL(/\/admins$/);
  await expect(page.getByRole('heading', { name: 'For admins' })).toBeVisible();
  await expect(page.getByText(/These commands can change the live server/)).toBeVisible();
  await expect(page.getByPlaceholder(/^Search/)).toBeVisible();

  // Commands are grouped into runbooks and shown without anything to expand.
  for (const section of ['Deploy a change', 'Add a person or change their access', 'Storage and backups']) {
    await expect(page.getByRole('heading', { name: section })).toBeVisible();
  }
  await expect(page.getByText('nix run .#validate-config-readiness')).toBeVisible();
  await expect(page.getByText('./scripts/deploy.sh --action test')).toBeVisible();
  await expect(page.getByText('systemctl status caddy.service --no-pager')).toBeVisible();
  // A command for a client device says so instead of looking like a server command.
  await expect(page.locator('.ops-cmd').filter({ hasText: 'Allow Jellyfin discovery replies on Windows' }))
    .toContainText('Windows client (Administrator PowerShell)');
  await expect(page.locator('.ops-cmd').filter({ hasText: 'Test deploy' })).toContainText('Repository folder');

  await page.getByText('Groups you can grant (10)').click();
  await expect(page.getByRole('row', { name: /photos-users/ })).toContainText('vars.nix');
  await expect(page.getByRole('row', { name: /files-sftp-users/ })).toContainText('A deploy keeps it.');
  await expectNoHorizontalOverflow(page);

  await page.getByPlaceholder(/^Search/).fill('snapshot');
  await expect(page.getByRole('heading', { name: 'Backup schedule' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Trigger snapshot now' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Test deploy' })).toHaveCount(0);

  await page.getByPlaceholder(/^Search/).fill('kanidm');
  for (const title of ['Verify user exists', 'Create user', 'Grant app access', 'Revoke access', 'Generate sign-in link']) {
    await expect(page.getByRole('heading', { name: title, exact: true })).toBeVisible();
  }

  await page.getByPlaceholder(/^Search/).fill('nonexistent');
  await expect(page.getByText('No commands or controls match your search.')).toBeVisible();

  await page.getByRole('link', { name: 'Detailed Guide' }).click();
  await expect(page).toHaveURL(/\/uploads$/);
  await page.getByRole('link', { name: /^Where files go/ }).click();
  await expect(page).toHaveURL(/\/uploads\?guide=folders$/);
  await expect(page.getByRole('heading', { name: 'Audiobooks' })).toBeVisible();
  // Each folder used to have a page of its own; those links now open the folder map.
  await page.goto('/uploads?guide=folder-audiobooks');
  await expect(page.getByRole('heading', { name: 'Where files go' })).toBeVisible();

  await page.locator('summary.profile-trigger').click();
  await expect(page.getByRole('heading', { name: 'dsaw' })).toBeVisible();
  await expect(page.getByLabel('Show inactive apps in Services')).not.toBeChecked();
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
  await expect(page.getByText('No enabled apps are currently assigned to this account')).toBeVisible();
  await expect(page.getByLabel('Your apps')).toHaveCount(0);

  await stepHeader(page, 'Add your files').click();
  await expect(page.getByText('Neither browser uploads nor SFTP/SSHFS are available to your account.')).toBeVisible();
  await expect(page.getByRole('link', { name: 'Open Files' })).toHaveCount(0);
  await expect(page.getByRole('link', { name: 'Set up SSHFS' })).toHaveCount(0);

  await stepHeader(page, 'Set up your phone and TV').click();
  await expect(page.getByText('None of the apps assigned to your account has a phone or TV app to set up.')).toBeVisible();
});

test('detailed guide opens on an index and independently reveals unused apps', async ({ page }) => {
  await page.setExtraHTTPHeaders({
    'x-forwarded-groups': 'users backup-admin files-personal-users files-sftp-users jellyfin-users photos-users',
  });
  await page.goto('/uploads');

  const contents = page.getByRole('navigation', { name: 'Detailed guide contents' });
  for (const topic of [
    'How sign-in works',
    'Where files go',
    'Mount your files as a drive',
    'Troubleshooting',
    'Photos',
    'Files',
    'Videos',
    'Offline Media',
    'Local Backups',
  ]) {
    await expect(contents.getByRole('link', { name: new RegExp(`^${topic}`) })).toBeVisible();
  }
  await expect(contents.getByRole('link', { name: /^Passwords/ })).toHaveCount(0);
  await expect(contents.getByRole('link', { name: /^Back up your password vault/ })).toHaveCount(0);
  await expectNoHorizontalOverflow(page);

  await contents.getByRole('link', { name: /^Photos/ }).click();
  await expect(page).toHaveURL(/\/uploads\?guide=service-photos$/);
  await expect(page.getByRole('heading', { level: 1, name: 'Photos' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Good to know' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Back up phone photos with Immich' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Open Photos' })).toHaveAttribute('target', '_blank');

  // Beside a topic the contents are a sidebar on a wide screen and a single way back on a phone.
  const sidebarTopics = page.locator('.guide-nav__lists');
  if ((page.viewportSize()?.width ?? 1280) <= 900) {
    await expect(sidebarTopics).toBeHidden();
  } else {
    await expect(sidebarTopics.getByRole('link', { name: 'Photos', exact: true })).toHaveAttribute('aria-current', 'page');
    await sidebarTopics.getByRole('link', { name: 'How sign-in works', exact: true }).click();
    await expect(page.getByRole('heading', { level: 1, name: 'How sign-in works' })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Apps with their own login' })).toBeVisible();
  }
  await expectNoHorizontalOverflow(page);

  await page.locator('summary.profile-trigger').click();
  await page.getByLabel('Show unused apps in Detailed Guide').check();
  await page.keyboard.press('Escape');
  await page.getByRole('link', { name: 'All topics' }).click();
  await expect(page).toHaveURL(/\/uploads$/);
  await expect(page.getByLabel('Include apps that are not enabled')).toBeChecked();
  await expect(contents.getByRole('link', { name: /^Passwords/ })).toBeVisible();
  await expect(contents.getByRole('link', { name: /^Back up your password vault/ })).toBeVisible();

  await page.getByRole('link', { name: 'Services', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Passwords is not active' })).toHaveCount(0);
  await page.getByRole('button', { name: 'Photos service information' }).click();
  await page.locator('summary.profile-trigger').click();
  await page.getByLabel('Show inactive apps in Services').check();
  await expect(page.getByRole('button', { name: 'Passwords is not active' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Photos service information' })).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'Photos', exact: true })).toHaveCount(0);
});

test('unused SSHFS guidance hides connection details from accounts without SSHFS access', async ({ page }) => {
  await page.setExtraHTTPHeaders({
    'x-forwarded-preferred-username': 'no-file-access',
    'x-forwarded-groups': 'users',
  });
  await page.goto('/uploads');

  await page.locator('summary.profile-trigger').click();
  await page.getByLabel('Show unused apps in Detailed Guide').check();
  // On phones the open profile menu overlaps the contents chips; close it as a tap outside would.
  await page.keyboard.press('Escape');
  await expect(page.getByLabel('Include apps that are not enabled')).toBeChecked();
  await page.getByRole('navigation', { name: 'Detailed guide contents' }).getByRole('link', { name: /^Mount your files as a drive/ }).click();

  await expect(page.getByText('Your account does not currently have SSHFS access.')).toBeVisible();
  await expect(page.getByText('server.home.arpa:2022', { exact: true })).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'Upload SSHFS Public Key' })).toHaveCount(0);
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
