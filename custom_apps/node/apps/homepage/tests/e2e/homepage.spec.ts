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

test('homepage navigation and SFTP upload flow stay client-side', async ({ page }) => {
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
  await expectNoHorizontalOverflow(page);

  const setup = page.locator('article').filter({ has: page.getByRole('heading', { name: 'SSHFS Mount Setup' }) });
  await expect(setup.locator('pre.windows code').first()).toBeVisible();
  await expect(setup.locator('pre.windows code').first()).toContainText('New-Item -ItemType Directory -Force');
  await expect(setup.locator('pre.windows code').first()).toContainText('ssh-keygen -t ed25519');
  await expect(setup.locator('pre.windows code').first()).toContainText('Get-Content $env:USERPROFILE');
  await expect(setup.getByText('Install WinFsp and SSHFS-Win before mounting the server.')).toBeVisible();
  await expect(setup.getByText('Mount the same drive automatically when Windows starts')).toBeVisible();
  await expect(setup.locator('pre code').filter({ hasText: '/persistent:yes' })).toBeVisible();

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
  await expect(page.getByText('SFTP public key saved and verified on the server.')).toBeVisible();
  await expect(page.getByText('owner=root:root mode=644')).toBeVisible();
});

test('top-level pages and profile menu render without full reloads', async ({ page }) => {
  await page.setExtraHTTPHeaders({
    'x-forwarded-groups': 'backup-admin files-personal-users',
  });
  await page.goto('/');

  await page.getByRole('link', { name: 'Getting Started' }).click();
  await expect(page).toHaveURL(/\/getting-started$/);
  await expect(page).toHaveTitle('Getting Started | Example Home Services');
  await expect(page.getByRole('heading', { name: 'Set up your account' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Protect your account' })).toBeVisible();
  await expect(page.getByText('Signed in as dsaw')).toBeVisible();
  await expect(page.getByLabel('Done', { exact: true }).first()).toBeVisible();
  await expect(page.getByRole('link', { name: 'Open Kanidm' })).toHaveAttribute('target', '_blank');

  await page.getByLabel('Checked my sign-in and account recovery options').check();
  await expect(page.getByLabel('Checked my sign-in and account recovery options')).toBeChecked();

  await page.getByText('Show all steps').click();
  await page.getByRole('navigation', { name: 'Getting started steps' }).getByRole('link', { name: 'Prepare for account recovery' }).click();
  await expect(page).toHaveURL(/\/getting-started\?step=recovery#guide$/);
  await expect(page.getByText('Keep a recovery copy outside this server', { exact: true })).toBeVisible();
  await page.getByText('Keep a recovery copy outside this server', { exact: true }).click();
  await expect(page.getByText('Windows Task Scheduler')).toBeVisible();
  await expect(page.getByText('macOS launchd')).toBeVisible();
  await expect(page.getByText('Linux systemd user timer')).toBeVisible();

  await page.getByText('Show all steps').click();
  await page.getByRole('navigation', { name: 'Getting started steps' }).getByRole('link', { name: 'Open your apps' }).click();
  await expect(page).toHaveURL(/\/getting-started\?step=services#guide$/);
  await expect(page.getByRole('heading', { name: 'Open your apps' })).toBeVisible();
  await expect(page.getByText('You currently have 4 apps.')).toBeVisible();
  await expect(page.getByLabel('Available services').getByText('Local Backups')).toBeVisible();
  await expect(page.getByLabel('Available services').getByText('Passwords')).toHaveCount(0);

  await page.getByText('Show all steps').click();
  await page.getByRole('navigation', { name: 'Getting started steps' }).getByRole('link', { name: 'Add your files' }).click();
  await expect(page).toHaveURL(/\/getting-started\?step=uploads#guide$/);
  await expect(page.getByRole('heading', { name: 'Choose how to add files' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Open Files' })).toHaveAttribute('target', '_blank');

  await page.getByRole('link', { name: 'For Admins' }).click();
  await expect(page).toHaveURL(/\/admins$/);
  await expect(page.getByRole('heading', { name: 'Admin tools' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'What do you need to do?' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Add a user' })).toBeVisible();
  await expect(page.getByRole('button', { name: "Change a user's access" })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Recover an account or manage secrets' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Search all commands' })).toBeVisible();
  await expect(page.getByText('Inspect before changing anything')).toBeVisible();
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
  await expect(page.getByText('kanidm person create "$NEW_USER" "$DISPLAY_NAME"')).toBeVisible();
  await page.getByRole('button', { name: 'Use my account details' }).click();
  const assignedGroups = page.locator('.group-picker-section').filter({ has: page.getByRole('heading', { name: 'Already assigned' }) });
  const unassignedGroups = page.locator('.group-picker-section').filter({ has: page.getByRole('heading', { name: 'Not assigned' }) });
  await expect(assignedGroups.getByText('backup-admin')).toBeVisible();
  await expect(assignedGroups.getByText('files-personal-users')).toBeVisible();
  await expect(unassignedGroups.getByText('photos-users')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Blank-machine install' })).toHaveCount(0);

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
