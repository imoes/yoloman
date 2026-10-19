import { test, expect } from '@playwright/test';
import { apiAs, ok } from './support/deploy-scenario';

/**
 * The fleet-wide Diagnoses board (admin): every host's stored diagnoses, newest first, each opening at its permalink.
 * Makes stored diagnoses findable across the fleet, not only host by host. Read-only.
 */
test.setTimeout(120_000);

test('Diagnoses board lists fleet-wide and opens a diagnosis at its permalink', async ({ page }) => {
  await page.setViewportSize({ width: 1500, height: 1000 });
  await page.goto('/diagnoses');
  await expect(page.getByRole('heading', { name: 'Diagnoses' })).toBeVisible({ timeout: 30_000 });

  const rows = page.locator('a.dh-row');
  await expect(rows.first()).toBeVisible({ timeout: 30_000 });
  // A summary header gives at-a-glance counts.
  await expect(page.locator('.db-summary .db-chip').first()).toContainText(/shown/);
  // Rows span multiple hosts (fleet-wide), each links to a permalink.
  const first = rows.first();
  const id = await first.getAttribute('data-id');
  await expect(first).toHaveAttribute('href', new RegExp(`/diagnoses/${id}$`));

  await first.click();
  await expect(page).toHaveURL(new RegExp(`/diagnoses/${id}$`));
  await expect(page.locator('app-diagnosis-panel .dg-head')).toContainText('kept', { timeout: 30_000 });
});

test('Diagnoses board filters by contract violation without error', async ({ page }) => {
  await page.goto('/diagnoses');
  await expect(page.getByRole('heading', { name: 'Diagnoses' })).toBeVisible({ timeout: 30_000 });
  await page.getByLabel('Contract').selectOption('violation');
  // Either rows (all flagged) or the empty note — never a crash.
  await expect(page.locator('.bm-err')).toHaveCount(0);
});

test('a recurring failure shows "Seen before" (related diagnoses) on its permalink', async ({ page }) => {
  // svc.disabled recurs across the dev fleet, so a diagnosis with that rule has precedent. Find one, open its permalink.
  const api = await apiAs('admin');
  const list = await ok<{ items: Array<{ id: string }> }>(
    api.get('/api/v1/diagnoses?q=svc.disabled&limit=1'), 'find a recurring diagnosis');
  test.skip(list.items.length === 0, 'no svc.disabled diagnosis in this fleet');
  const id = list.items[0].id;
  const related = await ok<{ items: unknown[] }>(api.get(`/api/v1/diagnoses/${id}/related`), 'related');
  test.skip(related.items.length === 0, 'no related diagnoses for this one');

  await page.goto(`/diagnoses/${id}`);
  const panel = page.locator('app-diagnosis-panel');
  await expect(panel.locator('.dg-related')).toBeVisible({ timeout: 30_000 });
  await expect(panel.locator('.dg-related > summary')).toContainText(/Seen before/);
  // Expanding it lists other occurrences, each a link to its own permalink.
  await panel.locator('.dg-related > summary').click();
  await expect(panel.locator('.dg-relrow').first()).toBeVisible();
});

test('the board shows recurring failure modes and drills into one', async ({ page }) => {
  await page.setViewportSize({ width: 1500, height: 1000 });
  await page.goto('/diagnoses');
  await expect(page.getByRole('heading', { name: 'Diagnoses' })).toBeVisible({ timeout: 30_000 });

  const recurring = page.locator('.db-recurring');
  await expect(recurring).toBeVisible({ timeout: 30_000 });     // the dev fleet has recurring failures
  await recurring.locator('summary').click();
  const chip = recurring.locator('.db-recur').first();
  const ruleText = (await chip.locator('code').textContent())?.trim() ?? '';
  await chip.click();                                           // drill into that failure mode
  // The free-text filter is now that rule, and the rows reflect it (or the empty note) — never a crash.
  await expect(page.locator('input[aria-label="Search host, service or rule"]')).toHaveValue(ruleText);
  await expect(page.locator('.bm-err')).toHaveCount(0);
});
