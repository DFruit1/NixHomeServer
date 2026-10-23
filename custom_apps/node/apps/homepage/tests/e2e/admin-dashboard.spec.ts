import { expect, test, type Page } from '@playwright/test';

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

test('admin dashboard renders the backup widgets from cached status', async ({ page }) => {
  await page.goto('/admin-dashboard');

  await expect(page.locator('h1')).toHaveText('Admin dashboard');
  await expect(page.locator('.dashboard-widget')).toHaveCount(2);
  await expect(page.getByRole('heading', { name: 'Backup freshness' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Dump verification' })).toBeVisible();

  const freshness = page.locator('.dashboard-widget', { hasText: 'Backup freshness' });
  await expect(freshness.locator('.dashboard-widget__badge')).toHaveText('Healthy');
  await expect(freshness.locator('dt')).toHaveText([
    'Status cache',
    'Kopia snapshot',
    'Kopia deep verify',
    'Logical backup',
    'Offsite MEGA sync',
    'ZFS snapshots',
  ]);
  await expect(freshness).toContainText('refreshed every 10m');
  await expect(freshness).toContainText('limit 1d 12h');
  await expect(freshness).toContainText('MEGA mirror verified');
  await expect(page.locator('.notice')).toHaveCount(0);

  const dumps = page.locator('.dashboard-widget', { hasText: 'Dump verification' });
  await expect(dumps.locator('.dashboard-widget__summary')).toContainText('2/2 dumps verified');
  await expect(dumps).toContainText('4.0 MiB');
  await expect(dumps).toContainText('8.0 MiB');

  await expect(page.locator('.tabs a[href="/admin-dashboard"]')).toHaveClass(/selected/);
  await expectNoHorizontalOverflow(page);
});

test('admin dashboard reports stale and missing items instead of showing healthy', async ({ page }) => {
  await page.route('**/api/admin-dashboard', async (route) => {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        available: true,
        generatedAt: '2026-10-24T07:00:00+00:00',
        generatedAgeSeconds: 2700,
        collectionState: 'warn',
        widgets: [
          {
            id: 'backup-freshness',
            title: 'Backup freshness',
            state: 'critical',
            summary: 'Kopia snapshot: 2d 0h old, limit 1d 12h',
            rows: [
              { label: 'Status cache', value: 'collected 45m\u00A0ago · refreshed every 10m', state: 'warn' },
              { label: 'Kopia snapshot', value: '2d 0h old, limit 1d 12h', state: 'critical' },
              { label: 'Offsite MEGA sync', value: 'MEGA mirror verified (last activity 1d 6h ago)', state: 'warn' },
            ],
            checkedAt: '2026-10-24T03:15:00+00:00',
          },
          {
            id: 'dump-verification',
            title: 'Dump verification',
            state: 'critical',
            summary: 'Missing dumps: paperless.dump',
            rows: [
              { label: 'kanidm.sqlite', value: 'sqlite · 4.0 MiB · integrity ok, 4h 0m old', state: 'ok' },
              { label: 'paperless.dump', value: 'expected dump is missing from the current generation', state: 'critical' },
            ],
          },
        ],
      }),
    });
  });

  await page.goto('/admin-dashboard');

  await expect(page.locator('.dashboard-widget.is-critical')).toHaveCount(2);
  await expect(page.locator('.notice')).toContainText('may have stopped');
  await expect(page.locator('.dashboard-widget__badge').first()).toHaveText('Action needed');
  await expect(page.locator('.dashboard-widget__row.is-critical')).toContainText(['2d 0h', 'missing']);
  await expect(page.locator('.dashboard-widget__row.is-warn').filter({ hasText: 'MEGA mirror verified' })).toHaveCount(1);
  await expect(page.locator('.dashboard-widget__row.is-warn').filter({ hasText: 'Status cache' })).toHaveCount(1);
  await expect(page.locator('.dashboard-widget__summary').nth(1)).toContainText('paperless.dump');
  await expectNoHorizontalOverflow(page);
});

test('admin dashboard shows an unreadable ZFS inventory as attention, not healthy', async ({ page }) => {
  await page.route('**/api/admin-dashboard', async (route) => {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        available: true,
        generatedAt: '2026-10-24T07:00:00+00:00',
        generatedAgeSeconds: 300,
        collectionState: 'ok',
        widgets: [
          {
            id: 'backup-freshness',
            title: 'Backup freshness',
            state: 'warn',
            summary: 'ZFS snapshots: tank ONLINE · the automatic-snapshot inventory could not be read',
            rows: [
              { label: 'Status cache', value: 'collected 5m\u00A0ago · refreshed every 10m', state: 'ok' },
              { label: 'Kopia snapshot', value: '2h 0m old, limit 1d 12h', state: 'ok' },
              {
                label: 'ZFS snapshots',
                value: 'tank ONLINE · the automatic-snapshot inventory could not be read',
                state: 'warn',
              },
            ],
          },
          {
            id: 'dump-verification',
            title: 'Dump verification',
            state: 'ok',
            summary: '2/2 dumps verified in the current generation.',
            rows: [{ label: 'Status cache', value: 'collected 5m\u00A0ago · refreshed every 10m', state: 'ok' }],
          },
        ],
      }),
    });
  });

  await page.goto('/admin-dashboard');

  const freshness = page.locator('.dashboard-widget', { hasText: 'Backup freshness' });
  await expect(freshness.locator('.dashboard-widget__badge')).toHaveText('Attention');
  await expect(freshness.locator('.dashboard-widget__summary')).toContainText('inventory could not be read');
  await expect(freshness.locator('.dashboard-widget__row.is-warn').filter({ hasText: 'ZFS snapshots' }))
    .toContainText('inventory could not be read');
  await expect(page.locator('.dashboard-widget__badge', { hasText: 'Healthy' })).toHaveCount(1);
  await expectNoHorizontalOverflow(page);
});

test('admin dashboard explains when no cached status exists yet', async ({ page }) => {
  await page.route('**/api/admin-dashboard', async (route) => {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        available: false,
        reason: 'no cached dashboard status is available yet',
        widgets: [],
      }),
    });
  });

  await page.goto('/admin-dashboard');

  await expect(page.locator('.empty-state h2')).toHaveText('No dashboard data yet');
  await expect(page.locator('.empty-state p')).toContainText('no cached dashboard status');
  await expect(page.locator('.dashboard-widget')).toHaveCount(0);
  await expectNoHorizontalOverflow(page);
});
