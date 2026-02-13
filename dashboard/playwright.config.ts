import { defineConfig, devices } from '@playwright/test';
import path from 'path';

const PORT = process.env.PORT || 3000;
const baseURL = `http://localhost:${PORT}`;

export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: 'html',
  use: {
    baseURL,
    trace: 'on-first-retry',
  },
  projects: [
    // Setup project for authentication
    {
      name: 'setup',
      testMatch: /.*\.setup\.ts/,
    },
    // Unauthenticated tests (login page)
    {
      name: 'unauthenticated',
      testMatch: /.*\.unauthenticated\.spec\.ts/,
      use: { ...devices['Desktop Chrome'] },
    },
    // Authenticated tests (dashboard)
    {
      name: 'chromium',
      testMatch: /.*\.spec\.ts/,
      testIgnore: /.*\.(setup|unauthenticated\.spec)\.ts/,
      use: {
        ...devices['Desktop Chrome'],
        storageState: path.join(__dirname, '.playwright/.auth/user.json'),
      },
      dependencies: ['setup'],
    },
  ],
  webServer: {
    command: `npm run dev -- -p ${PORT}`,
    url: baseURL,
    reuseExistingServer: !process.env.CI,
    timeout: 120000,
  },
});
