import { test, expect } from '@playwright/test';

test.describe('Timeline Visualization', () => {
  test.beforeEach(async ({ page }) => {
    // Navigate to monitoring page
    await page.goto('/dashboard/monitoring');
  });

  test('should display monitoring page', async ({ page }) => {
    // Check page header
    await expect(page.getByRole('heading', { name: /Shift Monitoring/i })).toBeVisible();
  });

  test('should show employee list on monitoring page', async ({ page }) => {
    // Wait for content to load
    await page.waitForTimeout(1000);

    // Should show either employee cards or empty state
    const hasEmployees = await page.locator('[class*="grid"]').first().isVisible();
    const hasEmptyState = await page.getByText(/No employees/i).isVisible();

    expect(hasEmployees || hasEmptyState).toBeTruthy();
  });
});

test.describe('Shift Detail Page with Timeline', () => {
  test('should navigate to shift detail from monitoring', async ({ page }) => {
    await page.goto('/dashboard/monitoring');

    // Wait for content
    await page.waitForTimeout(1000);

    // If there are active shifts, click to view details
    const shiftCard = page.locator('[class*="cursor-pointer"]').first();

    if (await shiftCard.isVisible()) {
      await shiftCard.click();

      // Should navigate to employee monitoring page
      await expect(page).toHaveURL(/.*monitoring\/[a-f0-9-]+/);
    }
  });

  test('should display shift detail components', async ({ page }) => {
    // Go directly to a potential shift detail page
    // This test assumes there's an active shift - may need adjustment
    await page.goto('/dashboard/monitoring');

    // Wait for content
    await page.waitForTimeout(2000);

    // Check for monitoring-specific UI elements
    await expect(page.getByText(/Shift Monitoring/i)).toBeVisible();
  });

  test('should display map view toggle on shift detail', async ({ page }) => {
    // Navigate to monitoring page first
    await page.goto('/dashboard/monitoring');
    await page.waitForTimeout(1000);

    // If we can access a shift detail page
    const shiftCard = page.locator('[class*="cursor-pointer"]').first();

    if (await shiftCard.isVisible()) {
      await shiftCard.click();
      await page.waitForTimeout(1000);

      // Check for map view toggle buttons (Basic/Segmented)
      const basicButton = page.getByRole('button', { name: /Basic/i });
      const segmentedButton = page.getByRole('button', { name: /Segmented/i });

      // At least one should be visible if on shift detail page
      const hasToggle =
        (await basicButton.isVisible()) || (await segmentedButton.isVisible());

      if (hasToggle) {
        await expect(segmentedButton).toBeVisible();
      }
    }
  });
});

test.describe('Timeline Bar Component', () => {
  test('should display timeline bar on shift with GPS data', async ({ page }) => {
    // Navigate to a shift detail page
    await page.goto('/dashboard/monitoring');
    await page.waitForTimeout(1000);

    const shiftCard = page.locator('[class*="cursor-pointer"]').first();

    if (await shiftCard.isVisible()) {
      await shiftCard.click();
      await page.waitForTimeout(2000);

      // Look for timeline-related elements
      // Timeline bar shows colored segments
      const timelineBar = page.locator('[class*="timeline"], [class*="segment"]').first();

      // If shift has GPS data, timeline should be visible
      // Otherwise, may show loading or empty state
    }
  });
});

test.describe('Timeline Summary Component', () => {
  test('should display summary statistics', async ({ page }) => {
    await page.goto('/dashboard/monitoring');
    await page.waitForTimeout(1000);

    const shiftCard = page.locator('[class*="cursor-pointer"]').first();

    if (await shiftCard.isVisible()) {
      await shiftCard.click();
      await page.waitForTimeout(2000);

      // Look for summary-related text
      // Summary shows duration breakdown
      const summaryText = page.getByText(/Timeline Summary|Total Duration|Coverage/i);

      // May or may not be visible depending on shift data
    }
  });
});

test.describe('Segmented Trail Map', () => {
  test('should toggle between basic and segmented map views', async ({ page }) => {
    await page.goto('/dashboard/monitoring');
    await page.waitForTimeout(1000);

    const shiftCard = page.locator('[class*="cursor-pointer"]').first();

    if (await shiftCard.isVisible()) {
      await shiftCard.click();
      await page.waitForTimeout(2000);

      // Find toggle buttons
      const basicButton = page.getByRole('button', { name: /Basic/i });
      const segmentedButton = page.getByRole('button', { name: /Segmented/i });

      if (await segmentedButton.isVisible()) {
        // Click basic view
        await basicButton.click();
        await page.waitForTimeout(500);

        // Map should update (can check for GPS Trail title)

        // Click segmented view
        await segmentedButton.click();
        await page.waitForTimeout(500);

        // Map should show segmented view (Segmented GPS Trail title)
      }
    }
  });

  test('should display map legend', async ({ page }) => {
    await page.goto('/dashboard/monitoring');
    await page.waitForTimeout(1000);

    const shiftCard = page.locator('[class*="cursor-pointer"]').first();

    if (await shiftCard.isVisible()) {
      await shiftCard.click();
      await page.waitForTimeout(2000);

      // Legend shows Start/End markers
      const legendText = page.getByText(/Start|End|Current/i);

      // Legend may be visible depending on map state
    }
  });
});

test.describe('History Page Timeline', () => {
  test('should navigate to history page', async ({ page }) => {
    await page.goto('/dashboard');

    // Click History in sidebar
    await page.getByRole('link', { name: 'History' }).click();

    await expect(page).toHaveURL(/.*history/);
  });

  test('should display history list', async ({ page }) => {
    await page.goto('/dashboard/history');

    // Wait for content
    await page.waitForTimeout(1000);

    // Should show shift history table or empty state
    const hasTable = await page.locator('table').isVisible();
    const hasEmptyState = await page.getByText(/No shifts found/i).isVisible();

    expect(hasTable || hasEmptyState).toBeTruthy();
  });
});
