import { defineConfig, devices } from '@playwright/test';

// The UI under test is the containerised dev build on :4201 (port 4200 on this machine belongs to another app —
// the old default silently tested the wrong product). The API is called directly for seeding.
export default defineConfig({
  testDir: './e2e',
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  workers: 2,
  retries: 0,
  use: {
    baseURL: process.env['BOSSMAN_UI_URL'] ?? 'http://localhost:4201',
    ignoreHTTPSErrors: true,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  reporter: [['list'], ['html', { outputFolder: 'playwright-report', open: 'never' }],
             ['json', { outputFile: 'test-results/results.json' }]],
  projects: [
    { name: 'setup', testMatch: /auth\.setup\.ts/ },
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'], storageState: 'e2e/.auth/admin.json' },
      dependencies: ['setup'],
    },
  ],
});
