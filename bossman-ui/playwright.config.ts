import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './e2e',
  timeout: 30_000,
  use: {
    baseURL: process.env['BOSSMAN_UI_URL'] ?? 'http://localhost:4200',
    ignoreHTTPSErrors: true,
  },
  reporter: [['list']],
});
