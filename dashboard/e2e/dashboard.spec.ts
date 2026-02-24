import { test, expect } from '@playwright/test';

test.describe('Dashboard App', () => {
  test('should redirect to dashboard from home', async ({ page }) => {
    await page.goto('/');

    // Should redirect to /dashboard
    await expect(page).toHaveURL(/.*dashboard/);
  });

  test('should display GPS Tracker branding', async ({ page }) => {
    await page.goto('/dashboard');

    // Check for GPS Tracker text in sidebar
    await expect(page.getByText('GPS Tracker')).toBeVisible();
  });

  test('should display navigation menu items', async ({ page }) => {
    await page.goto('/dashboard');

    // Check sidebar navigation links
    await expect(page.getByRole('link', { name: 'Overview' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Monitoring' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Teams' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Employees' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'History' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Locations' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Reports' })).toBeVisible();
  });

  test('should display stats cards on dashboard', async ({ page }) => {
    await page.goto('/dashboard');

    // Check for stats cards
    await expect(page.getByText('Total Employees')).toBeVisible();
    await expect(page.getByText('Active Shifts')).toBeVisible();
    await expect(page.getByText('Hours Today')).toBeVisible();
    await expect(page.getByText('Hours This Month')).toBeVisible();
  });

  test('should navigate to employees page', async ({ page }) => {
    await page.goto('/dashboard');

    await page.getByRole('link', { name: 'Employees' }).click();

    await expect(page).toHaveURL(/.*employees/);
  });

  test('should navigate to monitoring page', async ({ page }) => {
    await page.goto('/dashboard');

    await page.getByRole('link', { name: 'Monitoring' }).click();

    await expect(page).toHaveURL(/.*monitoring/);
  });

  test('should navigate to history page', async ({ page }) => {
    await page.goto('/dashboard');

    await page.getByRole('link', { name: 'History' }).click();

    await expect(page).toHaveURL(/.*history/);
  });

  test('should navigate to reports page', async ({ page }) => {
    await page.goto('/dashboard');

    await page.getByRole('link', { name: 'Reports' }).click();

    await expect(page).toHaveURL(/.*reports/);
  });

  test('should navigate to locations page', async ({ page }) => {
    await page.goto('/dashboard');

    await page.getByRole('link', { name: 'Locations' }).click();

    await expect(page).toHaveURL(/.*locations/);
  });
});
