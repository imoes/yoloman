import { test, expect } from '@playwright/test';
import { apiAs, ok } from './support/deploy-scenario';

/**
 * Past diagnoses and the diagnosis permalink (UX concept #3), against hal (the Linux dev host, which already has
 * saved diagnoses). "Past diagnoses…" on the Services snap-in lists the kept diagnoses newest-first; each row links
 * to the diagnosis at its own address (/diagnoses/:id), shown read-only as it was recorded — no "diagnose again",
 * because a saved diagnosis is what was true then, not a live re-run. All reads; nothing is asked of the host.
 */
test.setTimeout(120_000);

test('Past diagnoses list opens a diagnosis at its permalink, read-only', async ({ page }) => {
  await page.setViewportSize({ width: 1600, height: 1000 });
  await page.goto('/mmc');
  const select = page.getByRole('combobox', { name: 'Host' });
  const option = select.locator('option').filter({ hasText: /^\s*host4\.example\.internal( · |\s*$)/ }).first();
  await expect(option).toHaveCount(1, { timeout: 30_000 });
  await select.selectOption({ label: ((await option.textContent()) ?? '').trim() });

  const snapin = page.locator('.bm-snapin').filter({ has: page.locator('.bm-sname', { hasText: /^Services$/ }) });
  await expect(snapin).toBeVisible({ timeout: 30_000 });
  if (!(await snapin.locator('button.bm-node').first().isVisible())) await snapin.locator('.bm-snapin-head').click();
  await snapin.locator('button.bm-node').first().click();
  await expect(page.locator('.bm-result-head')).toContainText('host4.example.internal', { timeout: 60_000 });

  await page.getByRole('button', { name: /Past diagnoses/ }).click();
  const history = page.locator('app-diagnosis-history');
  await expect(history.locator('h3')).toContainText('Past diagnoses on host4.example.internal', { timeout: 30_000 });
  const rows = history.locator('a.dh-row');
  await expect(rows.first()).toBeVisible({ timeout: 30_000 });

  // Follow the first row to the permalink.
  const first = rows.first();
  const id = await first.getAttribute('data-id');
  await first.click();
  await expect(page).toHaveURL(new RegExp(`/diagnoses/${id}$`));

  const panel = page.locator('app-diagnosis-panel');
  await expect(panel.locator('article.dg-finding').first()).toBeVisible({ timeout: 30_000 });
  // It is a saved view: the "kept …" label is shown and "Diagnose again" is NOT offered.
  await expect(panel.locator('.dg-head')).toContainText('kept');
  await expect(panel.getByRole('button', { name: 'Diagnose again' })).toHaveCount(0);
});

test('A diagnosis permalink loads directly', async ({ page }) => {
  // Find any saved diagnosis id for hal through the API (with the admin token), then open its permalink cold.
  const halId = '9900fc29-baa9-405c-a0da-7174f3006537';
  const api = await apiAs('admin');
  const list = await ok<{ items: Array<{ id: string }> }>(api.get(`/api/v1/agents/${halId}/diagnoses?limit=1`), 'list diagnoses');
  test.skip(list.items.length === 0, 'no saved diagnosis for hal');

  await page.goto(`/diagnoses/${list.items[0].id}`);
  const panel = page.locator('app-diagnosis-panel');
  await expect(panel.locator('article.dg-finding').first()).toBeVisible({ timeout: 30_000 });
  await expect(panel.locator('.dg-head')).toContainText('kept');
});
