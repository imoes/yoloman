import { Page, expect } from '@playwright/test';

export async function login(page: Page, username = 'ui-e2e-admin', password = 'sup3rSecret!') {
  await page.goto('/');
  await expect(page).toHaveURL(/\/login/);
  await page.getByLabel('Username').fill(username);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/fleet/);
}
