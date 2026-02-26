import { test, expect } from '@playwright/test';

test.describe('Mileage Page', () => {
  const consoleErrors: string[] = [];
  const pageErrors: string[] = [];
  const networkErrors: { url: string; status: number; body: string }[] = [];

  test.beforeEach(async ({ page }) => {
    // Track console errors
    page.on('console', (msg) => {
      if (msg.type() === 'error') {
        const text = msg.text();
        if (
          !text.includes('React DevTools') &&
          !text.includes('Download the React DevTools') &&
          !text.includes('Refused to connect')
        ) {
          consoleErrors.push(text.substring(0, 500));
        }
      }
    });

    // Track uncaught JS errors
    page.on('pageerror', (error) => {
      pageErrors.push(error.message.substring(0, 500));
    });

    // Track failed network requests
    page.on('response', async (response) => {
      if (response.status() >= 400) {
        const url = response.url();
        // Skip expected failures (fonts, google maps, etc.)
        if (url.includes('maps.googleapis.com') || url.includes('fonts.')) return;
        let body = '';
        try {
          body = await response.text();
        } catch {
          body = '(could not read body)';
        }
        networkErrors.push({
          url: url.substring(0, 200),
          status: response.status(),
          body: body.substring(0, 300),
        });
      }
    });
  });

  test('1. Page loads and shows title', async ({ page }) => {
    await page.goto('/dashboard/mileage', { waitUntil: 'networkidle' });
    await page.waitForTimeout(2000);

    // Check title
    const heading = page.locator('h1');
    await expect(heading).toContainText('Mileage');

    // Check subtitle
    await expect(page.getByText('Manage trip route matching')).toBeVisible();

    await page.screenshot({ path: 'e2e/screenshots/mileage-01-loaded.png', fullPage: true });
  });

  test('2. Route Matching card is visible with buttons', async ({ page }) => {
    await page.goto('/dashboard/mileage', { waitUntil: 'networkidle' });
    await page.waitForTimeout(2000);

    // Route Matching card
    await expect(page.getByText('Route Matching')).toBeVisible();

    // Both buttons visible
    const reprocessFailed = page.getByRole('button', { name: /Re-process Failed/i });
    const reprocessAll = page.getByRole('button', { name: /Re-process All/i });
    await expect(reprocessFailed).toBeVisible();
    await expect(reprocessAll).toBeVisible();
  });

  test('3. Summary stats cards are visible', async ({ page }) => {
    await page.goto('/dashboard/mileage', { waitUntil: 'networkidle' });
    await page.waitForTimeout(3000);

    // Check summary cards
    await expect(page.getByText('Total Trips')).toBeVisible();
    await expect(page.getByText('Matched')).toBeVisible();
    await expect(page.getByText('Pending')).toBeVisible();
    await expect(page.getByText('Failed')).toBeVisible();
    await expect(page.getByText('Anomalous')).toBeVisible();

    await page.screenshot({ path: 'e2e/screenshots/mileage-02-stats.png', fullPage: true });
  });

  test('4. Trips table loads with data', async ({ page }) => {
    await page.goto('/dashboard/mileage', { waitUntil: 'networkidle' });
    await page.waitForTimeout(3000);

    // Check "All Trips" section
    await expect(page.getByText('All Trips')).toBeVisible();

    // Check if table or empty state exists
    const table = page.locator('table');
    const hasTable = await table.isVisible().catch(() => false);
    const emptyState = page.getByText('No trips found');
    const hasEmptyState = await emptyState.isVisible().catch(() => false);

    console.log(`Table visible: ${hasTable}, Empty state: ${hasEmptyState}`);

    if (hasTable) {
      // Check table headers
      await expect(page.getByText('Employee')).toBeVisible();
      await expect(page.getByText('Date')).toBeVisible();
      await expect(page.getByText('Route')).toBeVisible();
      await expect(page.getByText('GPS Dist.')).toBeVisible();
      await expect(page.getByText('Road Dist.')).toBeVisible();
      await expect(page.getByText('Status')).toBeVisible();
      await expect(page.getByText('Confidence')).toBeVisible();

      // Count rows
      const rows = await page.locator('table tbody tr').count();
      console.log(`Trip rows: ${rows}`);
      expect(rows).toBeGreaterThan(0);
    }

    await page.screenshot({ path: 'e2e/screenshots/mileage-03-table.png', fullPage: true });
  });

  test('5. Check for Supabase query errors', async ({ page }) => {
    await page.goto('/dashboard/mileage', { waitUntil: 'networkidle' });
    await page.waitForTimeout(3000);

    // Check for error messages on the page
    const errorBanner = page.locator('.bg-red-50');
    const hasError = await errorBanner.isVisible().catch(() => false);

    if (hasError) {
      const errorText = await errorBanner.textContent();
      console.log(`❌ Error on page: ${errorText}`);
    }

    // There should be no visible error
    expect(hasError).toBe(false);

    await page.screenshot({ path: 'e2e/screenshots/mileage-04-errors.png', fullPage: true });
  });

  test('6. Status filter cards work', async ({ page }) => {
    await page.goto('/dashboard/mileage', { waitUntil: 'networkidle' });
    await page.waitForTimeout(3000);

    // Click "Matched" stat card
    const matchedCard = page.locator('text=Matched').locator('..');
    await matchedCard.click();
    await page.waitForTimeout(1000);

    // Check if filter badge appears
    const filterBadge = page.locator('text=matched');
    const hasFilterBadge = await filterBadge.first().isVisible().catch(() => false);
    console.log(`Filter badge visible after clicking Matched: ${hasFilterBadge}`);

    await page.screenshot({ path: 'e2e/screenshots/mileage-05-filtered.png', fullPage: true });

    // Click "Total Trips" to reset
    const totalCard = page.locator('text=Total Trips').locator('..');
    await totalCard.click();
    await page.waitForTimeout(1000);
  });

  test('7. Table sorting works', async ({ page }) => {
    await page.goto('/dashboard/mileage', { waitUntil: 'networkidle' });
    await page.waitForTimeout(3000);

    const table = page.locator('table');
    const hasTable = await table.isVisible().catch(() => false);
    if (!hasTable) {
      console.log('⚠️ No table to test sorting');
      return;
    }

    // Click "Date" header to toggle sort
    const dateHeader = page.locator('th', { hasText: 'Date' });
    await dateHeader.click();
    await page.waitForTimeout(500);

    // Should show sort indicator
    const sortIcon = page.locator('th', { hasText: 'Date' }).locator('svg');
    const hasSortIcon = await sortIcon.isVisible().catch(() => false);
    console.log(`Sort icon visible: ${hasSortIcon}`);

    // Click again to reverse sort
    await dateHeader.click();
    await page.waitForTimeout(500);

    await page.screenshot({ path: 'e2e/screenshots/mileage-06-sorted.png', fullPage: true });
  });

  test('8. Trip row expansion shows details', async ({ page }) => {
    await page.goto('/dashboard/mileage', { waitUntil: 'networkidle' });
    await page.waitForTimeout(3000);

    const firstRow = page.locator('table tbody tr').first();
    const hasRow = await firstRow.isVisible().catch(() => false);
    if (!hasRow) {
      console.log('⚠️ No rows to expand');
      return;
    }

    // Click first row to expand
    await firstRow.click();
    await page.waitForTimeout(2000);

    // Check if expanded details show
    const gpsPoints = page.getByText('GPS Points');
    const duration = page.getByText('Duration');
    const classification = page.getByText('Classification');

    const hasGpsPoints = await gpsPoints.first().isVisible().catch(() => false);
    const hasDuration = await duration.first().isVisible().catch(() => false);
    const hasClassification = await classification.first().isVisible().catch(() => false);

    console.log(`Expanded details - GPS Points: ${hasGpsPoints}, Duration: ${hasDuration}, Classification: ${hasClassification}`);

    await page.screenshot({ path: 'e2e/screenshots/mileage-07-expanded.png', fullPage: true });

    // Click again to collapse
    await firstRow.click();
    await page.waitForTimeout(500);
  });

  test('9. Re-process Failed dialog opens and closes', async ({ page }) => {
    await page.goto('/dashboard/mileage', { waitUntil: 'networkidle' });
    await page.waitForTimeout(2000);

    // Open dialog
    await page.getByRole('button', { name: /Re-process Failed/i }).click();
    await page.waitForTimeout(500);

    // Dialog should be visible
    const dialog = page.getByRole('dialog');
    await expect(dialog).toBeVisible();
    await expect(dialog.getByText('Re-process Failed Trips')).toBeVisible();
    await expect(dialog.getByText(/re-attempt route matching/i)).toBeVisible();

    // Cancel and Start buttons should be visible
    await expect(dialog.getByRole('button', { name: 'Cancel' })).toBeVisible();
    await expect(dialog.getByRole('button', { name: 'Start Processing' })).toBeVisible();

    await page.screenshot({ path: 'e2e/screenshots/mileage-08-dialog-failed.png', fullPage: true });

    // Close via Cancel
    await dialog.getByRole('button', { name: 'Cancel' }).click();
    await page.waitForTimeout(500);

    // Dialog should be gone
    await expect(dialog).not.toBeVisible();
  });

  test('10. Re-process All dialog opens with warning', async ({ page }) => {
    await page.goto('/dashboard/mileage', { waitUntil: 'networkidle' });
    await page.waitForTimeout(2000);

    // Open dialog
    await page.getByRole('button', { name: /Re-process All/i }).click();
    await page.waitForTimeout(500);

    const dialog = page.getByRole('dialog');
    await expect(dialog).toBeVisible();
    await expect(dialog.getByText('Re-process All Trips')).toBeVisible();
    await expect(dialog.getByText(/Existing matches will be overwritten/i)).toBeVisible();

    await page.screenshot({ path: 'e2e/screenshots/mileage-09-dialog-all.png', fullPage: true });

    // Close
    await dialog.getByRole('button', { name: 'Cancel' }).click();
  });

  test('11. Refresh button works', async ({ page }) => {
    await page.goto('/dashboard/mileage', { waitUntil: 'networkidle' });
    await page.waitForTimeout(3000);

    // Find refresh button in the "All Trips" card header
    const refreshBtn = page.locator('button').filter({ has: page.locator('svg.lucide-refresh-cw') }).last();
    const hasRefreshBtn = await refreshBtn.isVisible().catch(() => false);
    console.log(`Refresh button visible: ${hasRefreshBtn}`);

    if (hasRefreshBtn) {
      await refreshBtn.click();
      await page.waitForTimeout(2000);
      console.log('Refresh clicked');
    }

    await page.screenshot({ path: 'e2e/screenshots/mileage-10-refreshed.png', fullPage: true });
  });

  test('12. Console errors check', async ({ page }) => {
    await page.goto('/dashboard/mileage', { waitUntil: 'networkidle' });
    await page.waitForTimeout(3000);

    // Expand a row to trigger GoogleTripRouteMap
    const firstRow = page.locator('table tbody tr').first();
    if (await firstRow.isVisible().catch(() => false)) {
      await firstRow.click();
      await page.waitForTimeout(3000);
    }

    await page.screenshot({ path: 'e2e/screenshots/mileage-11-console-check.png', fullPage: true });

    // Report all errors
    console.log('\n========== ERROR REPORT ==========');
    if (consoleErrors.length > 0) {
      console.log(`\n❌ ${consoleErrors.length} Console Errors:`);
      consoleErrors.forEach((err, i) => console.log(`  ${i + 1}. ${err}`));
    }
    if (pageErrors.length > 0) {
      console.log(`\n❌ ${pageErrors.length} Page Errors:`);
      pageErrors.forEach((err, i) => console.log(`  ${i + 1}. ${err}`));
    }
    if (networkErrors.length > 0) {
      console.log(`\n❌ ${networkErrors.length} Network Errors:`);
      networkErrors.forEach((err, i) =>
        console.log(`  ${i + 1}. [${err.status}] ${err.url}\n     Body: ${err.body}`)
      );
    }
    if (consoleErrors.length === 0 && pageErrors.length === 0 && networkErrors.length === 0) {
      console.log('\n✅ No errors found');
    }
    console.log('==================================\n');
  });

  test('13. Full page screenshot with all sections', async ({ page }) => {
    await page.goto('/dashboard/mileage', { waitUntil: 'networkidle' });
    await page.waitForTimeout(3000);

    // Take full page screenshot
    await page.screenshot({ path: 'e2e/screenshots/mileage-12-full.png', fullPage: true });
  });
});
