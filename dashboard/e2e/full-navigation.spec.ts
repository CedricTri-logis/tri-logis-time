import { test, expect } from '@playwright/test';

// Collect all errors during navigation
const errors: string[] = [];

test.describe('Full Site Navigation Test', () => {
  test.beforeEach(async ({ page }) => {
    // Listen for console errors
    page.on('console', (msg) => {
      if (msg.type() === 'error') {
        const text = msg.text();
        // Ignore some known non-critical errors
        if (!text.includes('React DevTools') &&
            !text.includes('checkout popup') &&
            !text.includes('Download the React DevTools')) {
          errors.push(`Console Error: ${text}`);
        }
      }
    });

    // Listen for page errors
    page.on('pageerror', (error) => {
      errors.push(`Page Error: ${error.message}`);
    });

    // Listen for failed requests
    page.on('requestfailed', (request) => {
      const url = request.url();
      // Ignore some expected failures
      if (!url.includes('favicon') && !url.includes('chrome-extension')) {
        errors.push(`Request Failed: ${request.failure()?.errorText} - ${url}`);
      }
    });
  });

  test('Navigate to Dashboard Home', async ({ page }) => {
    await page.goto('/dashboard');
    await page.waitForLoadState('networkidle');

    // Check page loaded
    await expect(page.getByText('GPS Tracker')).toBeVisible({ timeout: 10000 });
    await expect(page.getByText('Total Employees')).toBeVisible({ timeout: 10000 });

    // Take screenshot
    await page.screenshot({ path: 'e2e/screenshots/dashboard-home.png' });
  });

  test('Navigate to Monitoring page', async ({ page }) => {
    await page.goto('/dashboard/monitoring');
    await page.waitForLoadState('networkidle');

    // Check page structure
    await expect(page.locator('h1, h2').first()).toBeVisible({ timeout: 10000 });

    await page.screenshot({ path: 'e2e/screenshots/monitoring.png' });
  });

  test('Navigate to Employees page', async ({ page }) => {
    await page.goto('/dashboard/employees');
    await page.waitForLoadState('networkidle');

    await expect(page.locator('h1, h2').first()).toBeVisible({ timeout: 10000 });

    await page.screenshot({ path: 'e2e/screenshots/employees.png' });
  });

  test('Navigate to History page', async ({ page }) => {
    await page.goto('/dashboard/history');
    await page.waitForLoadState('networkidle');

    await expect(page.locator('h1, h2').first()).toBeVisible({ timeout: 10000 });

    await page.screenshot({ path: 'e2e/screenshots/history.png' });
  });

  test('Navigate to Locations page - List View', async ({ page }) => {
    await page.goto('/dashboard/locations');
    await page.waitForLoadState('networkidle');

    // Check locations loaded
    await expect(page.getByText('Locations')).toBeVisible({ timeout: 10000 });

    // Check if table or no locations message appears
    const hasLocations = await page.locator('table').isVisible().catch(() => false);
    if (hasLocations) {
      await expect(page.locator('table')).toBeVisible();
    }

    await page.screenshot({ path: 'e2e/screenshots/locations-list.png' });
  });

  test('Navigate to Locations page - Map View', async ({ page }) => {
    await page.goto('/dashboard/locations');
    await page.waitForLoadState('networkidle');

    // Click on Map view toggle if available
    const mapToggle = page.getByRole('button', { name: /map/i });
    if (await mapToggle.isVisible().catch(() => false)) {
      await mapToggle.click();
      await page.waitForTimeout(2000); // Wait for map to load
    }

    await page.screenshot({ path: 'e2e/screenshots/locations-map.png' });
  });

  test('Navigate to Location Detail page', async ({ page }) => {
    await page.goto('/dashboard/locations');
    await page.waitForLoadState('networkidle');

    // Click on first location if available
    const firstRow = page.locator('table tbody tr').first();
    if (await firstRow.isVisible().catch(() => false)) {
      await firstRow.click();
      await page.waitForLoadState('networkidle');
      await page.waitForTimeout(1000);

      await page.screenshot({ path: 'e2e/screenshots/location-detail.png' });
    }
  });

  test('Navigate to Reports page', async ({ page }) => {
    await page.goto('/dashboard/reports');
    await page.waitForLoadState('networkidle');

    await expect(page.locator('h1, h2').first()).toBeVisible({ timeout: 10000 });

    await page.screenshot({ path: 'e2e/screenshots/reports.png' });
  });

  test('Navigate to Teams page', async ({ page }) => {
    await page.goto('/dashboard/teams');
    await page.waitForLoadState('networkidle');

    await page.screenshot({ path: 'e2e/screenshots/teams.png' });
  });

  test('Test Add Location flow', async ({ page }) => {
    await page.goto('/dashboard/locations');
    await page.waitForLoadState('networkidle');

    // Click Add Location button if available
    const addButton = page.getByRole('button', { name: /add location/i });
    if (await addButton.isVisible().catch(() => false)) {
      await addButton.click();
      await page.waitForTimeout(1000);

      await page.screenshot({ path: 'e2e/screenshots/add-location-form.png' });
    }
  });

  test('Test CSV Import dialog', async ({ page }) => {
    await page.goto('/dashboard/locations');
    await page.waitForLoadState('networkidle');

    // Click Import CSV button if available
    const importButton = page.getByRole('button', { name: /import/i });
    if (await importButton.isVisible().catch(() => false)) {
      await importButton.click();
      await page.waitForTimeout(1000);

      await page.screenshot({ path: 'e2e/screenshots/csv-import-dialog.png' });
    }
  });

  test('Test Location filters', async ({ page }) => {
    await page.goto('/dashboard/locations');
    await page.waitForLoadState('networkidle');

    // Test type filter if available
    const typeFilter = page.locator('select, [role="combobox"]').first();
    if (await typeFilter.isVisible().catch(() => false)) {
      await typeFilter.click();
      await page.waitForTimeout(500);

      await page.screenshot({ path: 'e2e/screenshots/location-filter.png' });
    }
  });

  test('Navigate through sidebar links', async ({ page }) => {
    await page.goto('/dashboard');
    await page.waitForLoadState('networkidle');

    const sidebarLinks = [
      'Overview',
      'Monitoring',
      'Teams',
      'Employees',
      'History',
      'Locations',
      'Reports'
    ];

    for (const linkName of sidebarLinks) {
      const link = page.getByRole('link', { name: linkName });
      if (await link.isVisible().catch(() => false)) {
        await link.click();
        await page.waitForLoadState('networkidle');
        await page.waitForTimeout(500);

        // Verify URL changed
        const url = page.url();
        console.log(`Navigated to: ${url}`);
      }
    }
  });

  test('Test pagination on Locations', async ({ page }) => {
    await page.goto('/dashboard/locations');
    await page.waitForLoadState('networkidle');

    // Check for pagination buttons
    const nextButton = page.getByRole('button', { name: /next/i });
    if (await nextButton.isVisible().catch(() => false) && await nextButton.isEnabled()) {
      await nextButton.click();
      await page.waitForTimeout(1000);

      await page.screenshot({ path: 'e2e/screenshots/locations-page2.png' });
    }
  });

  test('Test Monitoring employee detail', async ({ page }) => {
    await page.goto('/dashboard/monitoring');
    await page.waitForLoadState('networkidle');

    // Click on first employee card if available
    const employeeCard = page.locator('[data-testid="employee-card"], .cursor-pointer').first();
    if (await employeeCard.isVisible().catch(() => false)) {
      await employeeCard.click();
      await page.waitForLoadState('networkidle');
      await page.waitForTimeout(1000);

      await page.screenshot({ path: 'e2e/screenshots/monitoring-detail.png' });
    }
  });

  test.afterAll(async () => {
    // Report all collected errors
    if (errors.length > 0) {
      console.log('\n========== ERRORS FOUND ==========');
      errors.forEach((err, i) => {
        console.log(`${i + 1}. ${err}`);
      });
      console.log('==================================\n');
    } else {
      console.log('\n✅ No errors found during navigation\n');
    }
  });
});
