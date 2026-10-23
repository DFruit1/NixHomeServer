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
    'Kopia snapshot',
    'Kopia deep verify',
    'Logical backup',
    'Offsite MEGA sync',
    'ZFS snapshots',
  ]);
  await expect(freshness).toContainText('limit 1d 12h');
  await expect(freshness).toContainText('MEGA mirror verified');

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
        generatedAgeSeconds: 120,
        widgets: [
          {
            id: 'backup-freshness',
            title: 'Backup freshness',
            state: 'critical',
            summary: 'Kopia snapshot: 2d 0h old, limit 1d 12h',
            rows: [
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
  await expect(page.locator('.dashboard-widget__badge').first()).toHaveText('Action needed');
  await expect(page.locator('.dashboard-widget__row.is-critical')).toContainText(['2d 0h', 'missing']);
  await expect(page.locator('.dashboard-widget__row.is-warn')).toContainText('MEGA mirror verified');
  await expect(page.locator('.dashboard-widget__summary').nth(1)).toContainText('paperless.dump');
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
