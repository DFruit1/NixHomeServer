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
  await expect(page.getByRole('navigation', { name: 'Homepage sections' })).toBeVisible();
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

  await page.getByRole('link', { name: 'How to Upload Files' }).click();
  await expect(page).toHaveURL(/\/uploads$/);
  await expect(page.getByRole('heading', { name: 'SSHFS Mount Setup' })).toBeVisible();
  await expect(page.getByText('Your account can also upload through https://files.example.test')).toBeVisible();
  await expectNoHorizontalOverflow(page);

  const setup = page.locator('article').filter({ has: page.getByRole('heading', { name: 'SSHFS Mount Setup' }) });
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
  await page.goto('/uploads');

  await expect(page.getByRole('heading', { name: 'SSHFS Mount Setup' })).toBeVisible();
  await expect(page.getByText('SFTP/SSHFS and browser Files access use separate permissions.')).toBeVisible();
  await expect(page.getByText('Browser uploads are not currently available to your account.')).toBeVisible();
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
    await page.goto('/uploads');

    await expect(page.getByRole('heading', { name: 'SSHFS Mount Setup' })).toBeVisible();
    await expect(page.getByText(role.visiblePath, { exact: false })).toBeVisible();
    await expect(page.locator('.guide-callout').filter({ hasText: 'Your SFTP root includes' })).toHaveCount(1);
    await expect(page.getByText('Browser uploads are not currently available to your account.')).toBeVisible();
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
  await expect(page.getByRole('heading', { name: 'Set up your account' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Protect your account' })).toBeVisible();
  await expect(page.getByText('Signed in as dsaw')).toBeVisible();
  await expect(page.getByText(/progress is saved only in this browser profile/)).toBeVisible();
  await expect(page.getByText(/It works once and expires after one hour/)).toBeVisible();
  await expect(page.getByText('Use a trusted network path.')).toBeVisible();
  await expect(page.getByText(/Never send an admin your password/)).toBeVisible();
  await expect(page.getByLabel('Done', { exact: true }).first()).toBeVisible();
  await expect(page.getByRole('link', { name: 'Open Kanidm' })).toHaveAttribute('target', '_blank');

  await page.getByLabel('Checked my sign-in and account recovery options').check();
  await expect(page.getByLabel('Checked my sign-in and account recovery options')).toBeChecked();

  await page.getByText('Show all steps').click();
  await page.getByRole('navigation', { name: 'Getting started steps' }).getByRole('link', { name: 'Prepare for account recovery' }).click();
  await expect(page).toHaveURL(/\/getting-started\?step=recovery#guide$/);
  await expect(page.getByText('The Passwords app is not available to you.')).toBeVisible();
  await expect(page.getByLabel('Stored account recovery details outside this server')).toBeVisible();
  await expect(page.getByText('Keep a recovery copy outside this server', { exact: true })).toHaveCount(0);
  await expect(page.getByText('Kanidm sign-in', { exact: true })).toBeVisible();
  await expect(page.getByText('Videos password', { exact: true })).toBeVisible();
  await expect(page.getByText('Local Backups password', { exact: true })).toBeVisible();

  await page.getByText('Show all steps').click();
  await page.getByRole('navigation', { name: 'Getting started steps' }).getByRole('link', { name: 'Open your apps' }).click();
  await expect(page).toHaveURL(/\/getting-started\?step=services#guide$/);
  await expect(page.getByRole('heading', { name: 'Open your apps' })).toBeVisible();
  await expect(page.getByText(/shows 5 installed apps your account is authorised to use/)).toBeVisible();
  await expect(page.getByLabel('Available services').getByText('Local Backups')).toBeVisible();
  await expect(page.getByLabel('Available services').getByText('Passwords')).toHaveCount(0);
  await expect(page.getByText('Videos uses a separate Jellyfin password.')).toBeVisible();
  await expect(page.getByText('Local Backups has two sign-in gates.')).toBeVisible();
  await expect(page.getByText('If access was just changed, refresh your sign-in first.')).toBeVisible();

  await page.getByText('Show all steps').click();
  await page.getByRole('navigation', { name: 'Getting started steps' }).getByRole('link', { name: 'Add your files' }).click();
  await expect(page).toHaveURL(/\/getting-started\?step=uploads#guide$/);
  await expect(page.getByRole('heading', { name: 'Choose how to add files' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Open Files' })).toHaveAttribute('target', '_blank');
  await expect(page.getByText(/Browser Files and SFTP\/SSHFS are separate permissions/)).toBeVisible();

  await page.getByRole('link', { name: 'For Admins' }).click();
  await expect(page).toHaveURL(/\/admins$/);
  await expect(page.getByRole('heading', { name: 'Admin tools' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'What do you need to do?' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Add a user' })).toBeVisible();
  await expect(page.getByRole('button', { name: "Change a user's access" })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Recover an account or manage secrets' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Search all commands' })).toBeVisible();
  await expect(page.getByText('Inspect before changing anything')).toBeVisible();
  await page.getByText('Inspect before changing anything').click();
  await expect(page.getByText('Confirm scope first.')).toBeVisible();
  await expect(page.getByText('Keep secrets out of commands and records.')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Open health checks' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Open deploy steps' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Open backup checks' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Server health' })).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'Deployments and apps' })).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'Deploys', exact: true })).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'User accounts and access' })).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'Storage & Backups' })).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'User Management' })).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'User Onboarding' })).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'Secrets' })).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'Config And Deploys' })).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'User Support' })).toHaveCount(0);
  await expect(page.getByText('Quickstart covers disk setup')).toHaveCount(0);
  await expect(page.getByText('Choose a task to see its checklist.')).toBeVisible();
  await page.getByRole('button', { name: 'Search all commands' }).click();
  await page.getByLabel('Search all admin commands').fill('regenerate');
  await expect(page.getByText('Create or replace encrypted secrets')).toBeVisible();
  await expect(page.getByText('Review evaluated config')).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'Deployments and apps' })).toHaveCount(0);
  await expect(page.getByText('nix run .#show-config-summary')).toBeHidden();
  await page.getByLabel('Search all admin commands').fill('Review evaluated config');
  await expect(page.getByRole('heading', { name: 'Server health' })).toBeVisible();
  await expect(page.getByText('nix run .#show-config-summary')).toBeVisible();
  await expect(page.getByText('Repository folder').first()).toBeVisible();
  await expect(page.getByText('kanidm person create "$NEW_USER" "$DISPLAY_NAME"')).toBeHidden();
  await page.getByRole('button', { name: 'Add a user' }).click();
  await expect(page.getByRole('heading', { name: 'What do you need to do?' })).toBeHidden();
  await expect(page.getByRole('heading', { name: 'Server health' })).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'Deploys', exact: true })).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'Secrets' })).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'User accounts and access' })).toBeVisible();
  await expect(page.getByText('New-user handoff order')).toBeVisible();
  await expect(page.getByText(/Create the one-time account link last/)).toBeVisible();
  await expect(page.getByText('kanidm person create "$NEW_USER" "$DISPLAY_NAME"')).toBeVisible();
  await expect(page.getByText('Passwords account step unavailable')).toBeVisible();
  await expect(page.getByText('The Passwords service is disabled in this server configuration.')).toBeVisible();
  await expect(page.getByText('Create Passwords account')).toHaveCount(0);
  await expect(page.getByText('Give a user their initial Jellyfin password')).toBeVisible();
  await expect(page.getByText('sudo jellyfin-initial-credential USERNAME')).toBeVisible();
  await expect(page.getByText('https://homepage.example.test/getting-started')).toBeVisible();
  await expect(page.getByLabel('Display name')).toBeVisible();
  await page.getByLabel('Display name').fill('Alice Example');
  await expect(page.getByText('kanidm person create "$NEW_USER" \'Alice Example\'')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Use my account details' })).toHaveCount(0);
  await expect(page.getByText('Create first sign-in link')).toBeVisible();
  await page.getByLabel('Username').fill('Alice');
  await expect(page.getByText(/usernames must start with a lower-case letter/)).toBeVisible();
  await page.getByRole('button', { name: "Change a user's access" }).click();
  await expect(page.getByText('Access changes and offboarding')).toBeVisible();
  await expect(page.getByText(/does not by itself delete app-local accounts/)).toBeVisible();
  await expect(page.getByLabel('Display name')).toHaveCount(0);
  await expect(page.getByLabel('Email')).toHaveCount(0);
  await expect(page.getByText('Create account recovery link')).toHaveCount(0);
  await page.getByRole('button', { name: 'Use my account details' }).click();
  const accessTask = page.locator('details.admin-task').filter({ hasText: 'Choose app and admin access' });
  await expect(accessTask.getByRole('button', { name: 'Grant access' })).toHaveAttribute('aria-pressed', 'true');
  await expect(accessTask.getByText('groups marked identity.appUsers cannot be changed independently')).toBeVisible();
  await expect(accessTask.getByText('Granting app-admin also grants that bundle')).toBeVisible();
  await expect(accessTask.getByText('Configured access boundaries and exceptions')).toBeVisible();
  await expect(accessTask.getByText(/Kopia then requires the shared native kopia-admin credential/)).toBeVisible();
  await expect(accessTask.getByText(/Browser Files access.*SFTP\/SSHFS access/)).toBeVisible();
  await accessTask.locator('label.group-picker__option').filter({ hasText: 'app-admin' }).getByRole('checkbox').check();
  await expect(accessTask.locator('label.group-picker__option').filter({ hasText: 'documents-users' }).getByRole('checkbox')).toBeChecked();
  await expect(accessTask.locator('.admin-code-card code')).toContainText('kanidm group add-members "$group"');
  await accessTask.locator('label.group-picker__option').filter({ hasText: 'app-admin' }).getByRole('checkbox').uncheck();
  await expect(accessTask.locator('label.group-picker__option').filter({ hasText: 'documents-users' }).getByRole('checkbox')).not.toBeChecked();
  await accessTask.locator('label.group-picker__option').filter({ hasText: 'documents-users' }).getByRole('checkbox').check();
  await expect(accessTask.getByText('identity.appUsers').first()).toBeVisible();
  await expect(accessTask.locator('label.group-picker__option').filter({ hasText: 'documents-users' }).getByRole('checkbox')).toBeChecked();
  const configuredGuidance = accessTask.locator('.guide-callout').filter({ hasText: 'Repository-managed access' });
  await expect(configuredGuidance).toContainText('edit before deploying');
  await expect(configuredGuidance).toContainText('add "dsaw" once to identity.appUsers');
  await expect(configuredGuidance).toContainText('This controls documents-users jellyfin-users photos-users');
  await expect(configuredGuidance).toContainText('This grants every enabled default app group above, not only one app.');
  await expect(configuredGuidance).toContainText('Run ./scripts/deploy.sh --action test');
  await expect(accessTask.locator('.admin-code-card')).toHaveCount(0);
  await accessTask.locator('label.group-picker__option').filter({ hasText: 'backup-storage-users' }).getByRole('checkbox').check();
  await expect(configuredGuidance).toContainText('add "dsaw" once to backupAccess.storageUsers');
  await expect(configuredGuidance).toContainText('read-only backup repository access, not Kopia administration');
  await expect(accessTask.locator('label.group-picker__option').filter({ hasText: 'backup-admin' })).toHaveCount(0);
  await page.getByLabel('Username').fill('someone-else');
  await expect(accessTask.locator('input[type="checkbox"]:checked')).toHaveCount(0);
  await expect(accessTask.locator('label.group-picker__option').filter({ hasText: 'backup-admin' }).getByRole('checkbox')).not.toBeChecked();
  await expect(configuredGuidance).toHaveCount(0);
  await accessTask.locator('label.group-picker__option').filter({ hasText: 'documents-users' }).getByRole('checkbox').check();
  await expect(configuredGuidance).toContainText('add "someone-else" once to identity.appUsers');
  await accessTask.locator('label.group-picker__option').filter({ hasText: 'backup-storage-users' }).getByRole('checkbox').check();
  await expect(accessTask.getByRole('heading', { name: 'Access to grant' })).toBeVisible();
  await expect(accessTask.getByText('Homepage does not query live membership for another person.')).toBeVisible();
  await accessTask.getByRole('button', { name: 'Revoke access' }).click();
  await expect(accessTask.getByRole('heading', { name: 'Access to revoke' })).toBeVisible();
  await expect(accessTask.getByText('Never revoke a group merely because it appears')).toBeVisible();
  await accessTask.locator('label.group-picker__option').filter({ hasText: 'files-personal-users' }).getByRole('checkbox').check();
  await expect(accessTask.locator('.admin-code-card code')).toContainText('kanidm group remove-members "$group"');
  await accessTask.locator('label.group-picker__option').filter({ hasText: 'photos-users' }).getByRole('checkbox').check();
  await expect(configuredGuidance).toContainText('remove "someone-else" from identity.appUsers and identity.appAdminUsers wherever present');
  await expect(configuredGuidance).toContainText('revokes the enabled default app bundle');
  await expect(page.getByRole('heading', { name: 'Blank-machine install' })).toHaveCount(0);
  await page.getByRole('button', { name: 'Recover an account or manage secrets' }).click();
  await expect(page.getByText('Recover the correct sign-in boundary')).toBeVisible();
  await expect(page.getByText(/does not reset a Vaultwarden master password/)).toBeVisible();
  await expect(page.getByText('Find user account')).toBeVisible();
  await expect(page.getByText('Create account recovery link')).toBeVisible();
  await expect(page.getByText('Passwords account step unavailable')).toHaveCount(0);
  await expect(page.getByLabel('Display name')).toHaveCount(0);
  await expect(page.getByLabel('Email')).toHaveCount(0);
  await page.getByRole('button', { name: 'Use my account details' }).click();
  await expect(page.getByLabel('Username')).toHaveValue('dsaw');
  await page.getByRole('button', { name: 'Add a user' }).click();
  await expect(page.getByLabel('Username')).toHaveValue('');
  await expect(page.getByLabel('Display name')).toHaveValue('');
  await expect(page.getByLabel('Email')).toHaveValue('');

  await page.getByRole('link', { name: 'How to Upload Files' }).click();
  await expect(page).toHaveURL(/\/uploads$/);
  await page.getByRole('link', { name: 'Audiobooks' }).click();
  await expect(page).toHaveURL(/\/uploads\?guide=audiobooks$/);
  await expect(page.getByRole('heading', { name: 'Audiobooks' })).toBeVisible();

  await page.locator('summary.profile-trigger').click();
  await expect(page.getByRole('heading', { name: 'dsaw' })).toBeVisible();
  await expect(page.getByLabel('Show unused apps')).not.toBeChecked();
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
  await expect(page.getByText('nix run .#show-config-summary')).toHaveCount(0);

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
  await expect(page.getByText(/shows 0 installed apps your account is authorised to use/)).toBeVisible();
  await expect(page.getByText('No enabled apps are currently assigned to this account')).toBeVisible();
  await expect(page.getByLabel('Opened the apps I plan to use')).toHaveCount(0);
  await expect(page.locator('.getting-started-step').getByLabel('Skip — not available for this account')).toBeVisible();

  await page.getByText('Show all steps').click();
  await page.getByRole('navigation', { name: 'Getting started steps' }).getByRole('link', { name: 'Finish' }).click();
  await expect(page.getByRole('heading', { name: 'Finish setup' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Open Upload Guide' })).toHaveCount(0);
  await expect(page.locator('.finish-next-steps').getByText('How to Upload Files')).toHaveCount(0);
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
  await expect(page.getByRole('region', { name: 'Services' })).toBeVisible();
});
