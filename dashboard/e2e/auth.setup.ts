import { test as setup, expect } from '@playwright/test';
import path from 'path';

const authFile = path.join(__dirname, '../.playwright/.auth/user.json');

setup('authenticate', async ({ page }) => {
  // Go to login page
  await page.goto('/login');

  // Fill in credentials (you'll need to set these in .env.test or use test credentials)
  await page.getByLabel('Email').fill(process.env.TEST_USER_EMAIL || 'admin@test.com');
  await page.getByLabel('Password').fill(process.env.TEST_USER_PASSWORD || 'testpassword');

  // Click sign in
  await page.getByRole('button', { name: 'Sign In' }).click();

  // Wait for redirect to dashboard
  await page.waitForURL(/.*dashboard/, { timeout: 10000 });

  // Save authenticated state
  await page.context().storageState({ path: authFile });
});
