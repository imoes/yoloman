import { test, expect } from '@playwright/test';

/**
 * The "Software updates" snap-in on a Windows host (plan B13): one snap-in for both families — on Windows its
 * Windows Update nodes serve, the package-manager node says why it cannot. Reads only; nothing is installed here
 * (installing is covered by the agent module's own verification and was done once, deliberately, on 2026-10-17).
 */
test.setTimeout(240_000);

test('Windows Update: pending updates with an install action, and the history with Windows result words', async ({ page }) => {
  await page.setViewportSize({ width: 1600, height: 1000 });
  await page.goto('/mmc');
  const select = page.getByRole('combobox', { name: 'Host' });
  const option = select.locator('option').filter({ hasText: /^\s*bossman-wintest( · |\s*$)/ }).first();
  await expect(option).toHaveCount(1, { timeout: 30_000 });
  await select.selectOption({ label: ((await option.textContent()) ?? '').trim() });

  const snapin = page.locator('.bm-snapin').filter({ has: page.locator('.bm-sname', { hasText: /^Software updates$/ }) });
  await expect(snapin).toBeVisible({ timeout: 30_000 });
  if (!(await snapin.locator('button.bm-node').first().isVisible())) await snapin.locator('.bm-snapin-head').click();

  await snapin.locator('button.bm-node', { hasText: 'Windows Update — pending' }).click();
  await expect(page.locator('.bm-result-head')).toContainText('row(s) · bossman-wintest', { timeout: 180_000 });
  const rows = page.locator('.bm-table tbody tr');
  await expect(rows.first().getByRole('cell').first()).toHaveText(/^\s*KB\d{6,8}\s*$/);
  await expect(rows.first().getByRole('button', { name: 'Install this update' })).toBeVisible();

  await snapin.locator('button.bm-node', { hasText: 'Update history' }).click();
  await page.locator('input.bm-filter').fill('KB5122882');
  const installed = page.locator('.bm-table tbody tr').filter({ hasText: 'KB5122882' }).first();
  await expect(installed).toContainText('Succeeded', { timeout: 180_000 });

  // the package-manager node of the same snap-in is named unavailable with its reason, not hidden
  await expect(snapin.locator('button.bm-node', { hasText: 'Pending updates' })).toHaveAttribute('title', /yoloman\.package_updates/);
});
