import { test, expect } from '@playwright/test';

// Skip auth for this exploratory test
test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Exploratory Navigation Test', () => {
  const errors: string[] = [];

  test.beforeEach(async ({ page }) => {
    // Listen for console errors
    page.on('console', (msg) => {
      if (msg.type() === 'error') {
        const text = msg.text();
        if (!text.includes('React DevTools') &&
            !text.includes('checkout popup') &&
            !text.includes('Download the React DevTools') &&
            !text.includes('Refused to connect')) {
          console.log(`❌ Console Error: ${text}`);
          errors.push(`Console: ${text.substring(0, 200)}`);
        }
      }
    });

    page.on('pageerror', (error) => {
      console.log(`❌ Page Error: ${error.message}`);
      errors.push(`Page: ${error.message.substring(0, 200)}`);
    });
  });

  test('1. Dashboard Home', async ({ page }) => {
    await page.goto('/dashboard', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(2000);

    const title = await page.title();
    console.log(`📄 Dashboard Home - Title: ${title}`);

    await page.screenshot({ path: 'e2e/screenshots/01-dashboard.png', fullPage: true });
  });

  test('2. Monitoring Page', async ({ page }) => {
    await page.goto('/dashboard/monitoring', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(2000);

    console.log(`📄 Monitoring Page loaded`);
    await page.screenshot({ path: 'e2e/screenshots/02-monitoring.png', fullPage: true });
  });

  test('3. Employees Page', async ({ page }) => {
    await page.goto('/dashboard/employees', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(2000);

    console.log(`📄 Employees Page loaded`);
    await page.screenshot({ path: 'e2e/screenshots/03-employees.png', fullPage: true });
  });

  test('4. History Page', async ({ page }) => {
    await page.goto('/dashboard/history', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(2000);

    console.log(`📄 History Page loaded`);
    await page.screenshot({ path: 'e2e/screenshots/04-history.png', fullPage: true });
  });

  test('5. Locations List Page', async ({ page }) => {
    await page.goto('/dashboard/locations', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(3000);

    console.log(`📄 Locations Page loaded`);

    // Check for table
    const table = page.locator('table');
    const hasTable = await table.isVisible().catch(() => false);
    console.log(`   Has table: ${hasTable}`);

    // Count rows
    if (hasTable) {
      const rows = await page.locator('table tbody tr').count();
      console.log(`   Rows found: ${rows}`);
    }

    await page.screenshot({ path: 'e2e/screenshots/05-locations-list.png', fullPage: true });
  });

  test('6. Locations Map View', async ({ page }) => {
    await page.goto('/dashboard/locations', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(2000);

    // Try to click Map view toggle
    const mapButton = page.locator('button:has-text("Map"), [data-value="map"]');
    if (await mapButton.first().isVisible().catch(() => false)) {
      await mapButton.first().click();
      await page.waitForTimeout(3000);
      console.log(`📄 Locations Map View loaded`);
    } else {
      console.log(`⚠️ Map toggle not found`);
    }

    await page.screenshot({ path: 'e2e/screenshots/06-locations-map.png', fullPage: true });
  });

  test('7. Location Detail Page', async ({ page }) => {
    await page.goto('/dashboard/locations', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(2000);

    // Click on first location row
    const firstRow = page.locator('table tbody tr').first();
    if (await firstRow.isVisible().catch(() => false)) {
      await firstRow.click();
      await page.waitForTimeout(3000);

      const url = page.url();
      console.log(`📄 Location Detail - URL: ${url}`);
    } else {
      console.log(`⚠️ No location rows found`);
    }

    await page.screenshot({ path: 'e2e/screenshots/07-location-detail.png', fullPage: true });
  });

  test('8. Add Location Form', async ({ page }) => {
    await page.goto('/dashboard/locations', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(2000);

    // Click Add Location button
    const addButton = page.locator('button:has-text("Add Location"), button:has-text("Add")').first();
    if (await addButton.isVisible().catch(() => false)) {
      await addButton.click();
      await page.waitForTimeout(2000);
      console.log(`📄 Add Location form opened`);
    } else {
      console.log(`⚠️ Add button not found`);
    }

    await page.screenshot({ path: 'e2e/screenshots/08-add-location.png', fullPage: true });
  });

  test('9. Reports Page', async ({ page }) => {
    await page.goto('/dashboard/reports', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(2000);

    console.log(`📄 Reports Page loaded`);
    await page.screenshot({ path: 'e2e/screenshots/09-reports.png', fullPage: true });
  });

  test('10. Teams Page', async ({ page }) => {
    await page.goto('/dashboard/teams', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(2000);

    console.log(`📄 Teams Page loaded`);
    await page.screenshot({ path: 'e2e/screenshots/10-teams.png', fullPage: true });
  });

  test('11. Locations Pagination', async ({ page }) => {
    await page.goto('/dashboard/locations', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(2000);

    // Click next page if available
    const nextButton = page.locator('button:has-text("Next"), button[aria-label*="next"]').first();
    if (await nextButton.isVisible().catch(() => false)) {
      const isDisabled = await nextButton.isDisabled();
      if (!isDisabled) {
        await nextButton.click();
        await page.waitForTimeout(2000);
        console.log(`📄 Navigated to page 2`);
      } else {
        console.log(`⚠️ Next button is disabled`);
      }
    } else {
      console.log(`⚠️ Next button not found`);
    }

    await page.screenshot({ path: 'e2e/screenshots/11-locations-page2.png', fullPage: true });
  });

  test('12. Location Type Filter', async ({ page }) => {
    await page.goto('/dashboard/locations', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(2000);

    // Try to use type filter
    const typeSelect = page.locator('select, [role="combobox"]').first();
    if (await typeSelect.isVisible().catch(() => false)) {
      await typeSelect.click();
      await page.waitForTimeout(1000);
      console.log(`📄 Type filter opened`);

      // Select "building" if available
      const buildingOption = page.locator('text=Construction Site, text=Building, [data-value="building"]').first();
      if (await buildingOption.isVisible().catch(() => false)) {
        await buildingOption.click();
        await page.waitForTimeout(2000);
        console.log(`   Selected building filter`);
      }
    }

    await page.screenshot({ path: 'e2e/screenshots/12-filter.png', fullPage: true });
  });

  test('13. CSV Import Dialog', async ({ page }) => {
    await page.goto('/dashboard/locations', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(2000);

    // Click Import button
    const importButton = page.locator('button:has-text("Import")').first();
    if (await importButton.isVisible().catch(() => false)) {
      await importButton.click();
      await page.waitForTimeout(2000);
      console.log(`📄 Import dialog opened`);
    } else {
      console.log(`⚠️ Import button not found`);
    }

    await page.screenshot({ path: 'e2e/screenshots/13-import-dialog.png', fullPage: true });
  });

  test.afterAll(async () => {
    console.log('\n========================================');
    console.log('NAVIGATION TEST COMPLETE');
    console.log('========================================');
    if (errors.length > 0) {
      console.log(`\n❌ ${errors.length} ERRORS FOUND:\n`);
      errors.forEach((err, i) => {
        console.log(`${i + 1}. ${err}\n`);
      });
    } else {
      console.log('\n✅ No critical errors found\n');
    }
  });
});
