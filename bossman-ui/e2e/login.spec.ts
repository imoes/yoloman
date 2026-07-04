import { test, expect } from '@playwright/test';
import { login } from './helpers';

test('unauthenticated visit redirects to login', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveURL(/\/login/);
  await expect(page.getByText('Bossman')).toBeVisible();
});

test('wrong credentials are rejected', async ({ page }) => {
  await page.goto('/login');
  await page.getByLabel('Username').fill('nobody');
  await page.getByLabel('Password').fill('wrong');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByText('Invalid username or password')).toBeVisible();
  await expect(page).toHaveURL(/\/login/);
});

test('login succeeds and shows the persistent nav', async ({ page }) => {
  await login(page);
  await expect(page.getByRole('heading', { name: 'Fleet Overview' })).toBeVisible();
  for (const label of ['Fleet Overview', 'Hosts', 'Topology', 'Plans', 'Runs', 'Settings']) {
    await expect(page.getByRole('link', { name: label })).toBeVisible();
  }
});

test('logout returns to the login page', async ({ page }) => {
  await login(page);
  await page.getByRole('button', { name: 'Log out' }).click();
  await expect(page).toHaveURL(/\/login/);
});
