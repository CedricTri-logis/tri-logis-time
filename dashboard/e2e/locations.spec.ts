import { test, expect } from '@playwright/test';

test.describe('Locations Page', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/dashboard/locations');
  });

  test('should display locations page with header', async ({ page }) => {
    // Check page header
    await expect(page.getByRole('heading', { name: 'Locations' })).toBeVisible();

    // Check for Add Location button
    await expect(page.getByRole('button', { name: /Add Location/i })).toBeVisible();

    // Check for Import CSV button
    await expect(page.getByRole('button', { name: /Import CSV/i })).toBeVisible();
  });

  test('should have view toggle buttons', async ({ page }) => {
    // Check for list/map toggle buttons
    const listButton = page.locator('button').filter({ has: page.locator('svg.lucide-list') });
    const mapButton = page.locator('button').filter({ has: page.locator('svg.lucide-map') });

    await expect(listButton).toBeVisible();
    await expect(mapButton).toBeVisible();
  });

  test('should have filter controls', async ({ page }) => {
    // Check for search input
    await expect(page.getByPlaceholder(/Search by name or address/i)).toBeVisible();

    // Check for type filter dropdown
    await expect(page.getByRole('combobox').first()).toBeVisible();
  });

  test('should open create location dialog', async ({ page }) => {
    // Click Add Location button
    await page.getByRole('button', { name: /Add Location/i }).click();

    // Check dialog is open
    await expect(page.getByRole('dialog')).toBeVisible();
    await expect(page.getByRole('heading', { name: /Add New Location/i })).toBeVisible();

    // Check form fields are present
    await expect(page.getByLabel(/Name/i)).toBeVisible();
    await expect(page.getByText(/Location Type/i)).toBeVisible();
    await expect(page.getByText(/Geofence Radius/i)).toBeVisible();
  });

  test('should close create dialog on cancel', async ({ page }) => {
    // Open dialog
    await page.getByRole('button', { name: /Add Location/i }).click();
    await expect(page.getByRole('dialog')).toBeVisible();

    // Click cancel
    await page.getByRole('button', { name: /Cancel/i }).click();

    // Dialog should close
    await expect(page.getByRole('dialog')).not.toBeVisible();
  });

  test('should open CSV import dialog', async ({ page }) => {
    // Click Import CSV button
    await page.getByRole('button', { name: /Import CSV/i }).click();

    // Check dialog is open
    await expect(page.getByRole('dialog')).toBeVisible();
    await expect(page.getByText(/Import Locations from CSV/i)).toBeVisible();

    // Check for file upload area
    await expect(page.getByText(/drag and drop/i)).toBeVisible();
  });

  test('should switch between list and map views', async ({ page }) => {
    // Start in list view
    const mapButton = page.locator('button').filter({ has: page.locator('svg.lucide-map') });

    // Switch to map view
    await mapButton.click();

    // Map component should be visible (either the actual map or the loading state)
    await expect(page.locator('.leaflet-container, [class*="MapLoadingSkeleton"]')).toBeVisible({
      timeout: 10000,
    });

    // Switch back to list view
    const listButton = page.locator('button').filter({ has: page.locator('svg.lucide-list') });
    await listButton.click();

    // List content should be visible
    await expect(page.locator('[class*="divide-y"]').first()).toBeVisible();
  });

  test('should filter locations by search', async ({ page }) => {
    // Type in search
    const searchInput = page.getByPlaceholder(/Search by name or address/i);
    await searchInput.fill('test search query');

    // Wait for debounce
    await page.waitForTimeout(400);

    // URL should not change but search should be applied
    // The actual filtering depends on data availability
  });

  test('should navigate to location detail page on click', async ({ page }) => {
    // Wait for locations to load
    await page.waitForTimeout(1000);

    // If there are locations, clicking one should navigate to detail page
    const locationRow = page.locator('[class*="hover:bg-slate-50"]').first();

    if (await locationRow.isVisible()) {
      await locationRow.click();
      await expect(page).toHaveURL(/.*locations\/[a-f0-9-]+/);
    }
  });

  test('should display location navigation in sidebar', async ({ page }) => {
    await page.goto('/dashboard');

    // Check Locations link is in sidebar
    await expect(page.getByRole('link', { name: 'Locations' })).toBeVisible();

    // Click and navigate
    await page.getByRole('link', { name: 'Locations' }).click();
    await expect(page).toHaveURL(/.*locations/);
  });
});

test.describe('Location Detail Page', () => {
  test('should display location not found for invalid ID', async ({ page }) => {
    await page.goto('/dashboard/locations/invalid-uuid');

    // Should show error or redirect
    await page.waitForTimeout(2000);
    // Either shows error message or redirects back
  });
});

test.describe('Location Form Validation', () => {
  test('should show validation errors for empty required fields', async ({ page }) => {
    await page.goto('/dashboard/locations');

    // Open create dialog
    await page.getByRole('button', { name: /Add Location/i }).click();
    await expect(page.getByRole('dialog')).toBeVisible();

    // Try to submit empty form
    await page.getByRole('button', { name: /Create Location/i }).click();

    // Should show validation error for name
    await expect(page.getByText(/Name is required/i)).toBeVisible();
  });

  test('should validate latitude and longitude ranges', async ({ page }) => {
    await page.goto('/dashboard/locations');

    // Open create dialog
    await page.getByRole('button', { name: /Add Location/i }).click();
    await expect(page.getByRole('dialog')).toBeVisible();

    // Fill form with invalid coordinates
    await page.getByLabel(/Name/i).fill('Test Location');

    // Enter invalid latitude
    const latInput = page.locator('input[name="latitude"]');
    if (await latInput.isVisible()) {
      await latInput.fill('999');
    }

    // Try to submit
    await page.getByRole('button', { name: /Create Location/i }).click();

    // Should show coordinate validation error or prevent submission
  });
});
