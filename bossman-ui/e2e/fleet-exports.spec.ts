import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';

/**
 * Exportable fleet reports (monitoring gap #5, CSV slice). The fleet boards can hand their current table to the
 * browser as a CSV via one shared helper (shared/csv.ts). This drives the Capacity board end to end: the board loads
 * its forecast rows, "Export CSV" downloads a file, and the file is real CSV with the expected header and the rows.
 */
test.setTimeout(120_000);

test('Capacity board exports its forecast as CSV', async ({ page }) => {
  await page.setViewportSize({ width: 1500, height: 1000 });
  await page.goto('/capacity');

  // The board auto-loads; wait for rows so the export has something to write.
  await expect(page.locator('.bm-page')).toContainText('Capacity forecast', { timeout: 30_000 });
  const rows = page.locator('table tbody tr');
  await expect(rows.first()).toBeVisible({ timeout: 60_000 });

  const exportBtn = page.getByRole('button', { name: /Export CSV/ });
  await expect(exportBtn).toBeEnabled();
  const [download] = await Promise.all([
    page.waitForEvent('download'),
    exportBtn.click(),
  ]);
  expect(download.suggestedFilename()).toMatch(/^capacity-.*\.csv$/);

  const path = await download.path();
  const csv = readFileSync(path, 'utf8');
  const lines = csv.split('\r\n');
  expect(lines[0]).toBe('host,resource,status,current_pct,threshold_pct,growth_per_day_pct,days_to_threshold,eta');
  expect(lines.length).toBeGreaterThan(1);                 // at least one data row
  expect(lines[1].split(',').length).toBe(8);              // the columns line up
});

test('Audit log exports the full filtered trail as CSV (server-side)', async ({ page }) => {
  await page.setViewportSize({ width: 1500, height: 1000 });
  await page.goto('/audit');
  await expect(page.locator('.bm-page')).toContainText('Audit log', { timeout: 30_000 });

  const exportBtn = page.getByRole('button', { name: /Export CSV/ });
  await expect(exportBtn).toBeVisible();
  const [download] = await Promise.all([
    page.waitForEvent('download'),
    exportBtn.click(),
  ]);
  expect(download.suggestedFilename()).toBe('audit.csv');
  const csv = readFileSync(await download.path(), 'utf8');
  // Server-generated: the header is fixed, and the login that just happened is in the trail.
  expect(csv.split('\n')[0].trim()).toBe('at,actor,actor_kind,action,category,method,path,target,status,status_code,source_ip,detail');
  expect(csv).toContain('auth.login');
});

test('Security board exports the CVE findings as CSV', async ({ page }) => {
  await page.setViewportSize({ width: 1500, height: 1000 });
  await page.goto('/security');
  await expect(page.locator('.bm-page, .bm-head')).toContainText('Security', { timeout: 30_000 });

  const exportBtn = page.getByRole('button', { name: /Export CSV/ });
  // The board has CVEs in this fleet, so the button is enabled.
  await expect(exportBtn).toBeEnabled({ timeout: 60_000 });
  const [download] = await Promise.all([
    page.waitForEvent('download'),
    exportBtn.click(),
  ]);
  expect(download.suggestedFilename()).toBe('cves.csv');
  const csv = readFileSync(await download.path(), 'utf8');
  const lines = csv.split('\r\n');
  expect(lines[0]).toBe('cve,severity,distro,host,package,current_version,fixed_version,description');
  expect(lines.length).toBeGreaterThan(1);
  expect(lines[1]).toMatch(/^CVE-/i);                      // a real CVE row
});
