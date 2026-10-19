import { test as setup, expect, request } from '@playwright/test';
import { API_URL, BOOTSTRAP, USERS, UserKey, authFile } from './support/env';

// Creates the suite's accounts through the API (idempotent: an existing account is reset to the known password)
// and signs each one in through the REAL login form, saving the browser state the other projects reuse.
setup('create the test accounts and sign each in', async ({ browser }) => {
  const api = await request.newContext({ baseURL: API_URL });
  const login = await api.post('/api/v1/auth/login', { data: BOOTSTRAP });
  expect(login.ok(), `bootstrap admin login (${BOOTSTRAP.username})`).toBeTruthy();
  const token = (await login.json()).access_token as string;
  const auth = { Authorization: `Bearer ${token}` };

  for (const u of Object.values(USERS)) {
    const r = await api.post('/api/v1/users', { headers: auth, data: u });
    if (!r.ok()) {
      // It exists already: reset it to the known password and role (PATCH addresses users by username).
      const p = await api.patch(`/api/v1/users/${u.username}`, { headers: auth, data: { password: u.password, role: u.role } });
      expect(p.ok(), `create/reset ${u.username}: POST ${r.status()}, PATCH ${p.status()}`).toBeTruthy();
    }
  }

  for (const key of Object.keys(USERS) as UserKey[]) {
    const u = USERS[key];
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    await page.goto('/login');
    await page.getByLabel('Username').fill(u.username);
    await page.getByLabel('Password').fill(u.password);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).not.toHaveURL(/\/login/);
    await ctx.storageState({ path: authFile(key) });
    await ctx.close();
  }
});
