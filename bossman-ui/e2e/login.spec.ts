import { test, expect } from '@playwright/test';
import { USERS } from './support/env';

// The login screen is the one place the suite must start signed OUT: the chromium project hands every spec the
// admin's storage state, so this file clears it.
test.use({ storageState: { cookies: [], origins: [] } });

async function signIn(page: import('@playwright/test').Page, u: { username: string; password: string } = USERS.admin) {
  await page.goto('/login');
  await page.getByLabel('Username').fill(u.username);
  await page.getByLabel('Password').fill(u.password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/fleet/);
}

test('an unauthenticated visit lands on the login form', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveURL(/\/login/);
  await expect(page.getByRole('img', { name: /Bossman/ })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Sign in' })).toBeVisible();
});

test('a deep link while signed out also goes to the login form', async ({ page }) => {
  await page.goto('/kubernetes');
  await expect(page).toHaveURL(/\/login/);
});

test('wrong credentials are refused with the reason, and the form stays', async ({ page }) => {
  await page.goto('/login');
  await page.getByLabel('Username').fill('nobody');
  await page.getByLabel('Password').fill('wrong');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByText('Invalid username or password')).toBeVisible();
  await expect(page).toHaveURL(/\/login/);
});

test('signing in shows the Fleet Overview and the workspace navigation', async ({ page }) => {
  await signIn(page);
  await expect(page.getByRole('heading', { name: 'Fleet Overview', level: 1 })).toBeVisible();
  const workspaces = page.getByRole('tablist', { name: 'Workspaces' });
  for (const ws of ['Monitor', 'Fleet', 'Library', 'Deploy', 'Admin']) {
    await expect(workspaces.getByRole('tab', { name: ws })).toBeVisible();
  }
  // The Monitor workspace is the landing one; its items are links in the nav.
  const nav = page.getByRole('navigation', { name: 'Main navigation' });
  for (const href of ['/fleet', '/problems', '/runs']) {
    await expect(nav.locator(`a.bm-nav-item[href="${href}"]`)).toBeVisible();
  }
  // Switching workspace swaps the nav items: Fleet holds Hosts, Library holds Roles.
  await workspaces.getByRole('tab', { name: 'Fleet' }).click();
  await expect(nav.locator('a.bm-nav-item[href="/hosts"]')).toBeVisible();
  await workspaces.getByRole('tab', { name: 'Library' }).click();
  await expect(nav.locator('a.bm-nav-item[href="/plan-library"]')).toBeVisible();
  await expect(nav.getByText(USERS.admin.username)).toBeVisible();
});

test('logging out returns to the login form and the session is gone', async ({ page }) => {
  await signIn(page);
  await page.getByRole('button', { name: 'Log out' }).click();
  await expect(page).toHaveURL(/\/login/);
  await page.goto('/hosts');
  await expect(page).toHaveURL(/\/login/);
});
