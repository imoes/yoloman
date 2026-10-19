import { test, expect } from '@playwright/test';

/**
 * The "Recent incidents…" timeline on the Services snap-in (peer UX concept #2, docs/diagnosis.md). A LIVE read of
 * the host's incident ring — the same crashes/OOM-kills a diagnosis cites — so nothing is installed or stored here.
 *
 * It runs against hal, the Linux dev host: its agent HAS the recent_incidents module but the eBPF collector is off,
 * so the honest answer is a NAMED `not_supported` ring state, shown as such — the point of the feature is that an
 * empty answer is never dressed up as "no crashes". An agent too old to have the module greys the action out instead
 * (covered by the console's blocked-reason handling and the API's 501, tested elsewhere).
 */
test.setTimeout(120_000);

test('Recent incidents: a live timeline with the ring state said plainly', async ({ page }) => {
  await page.setViewportSize({ width: 1600, height: 1000 });
  await page.goto('/mmc');
  const select = page.getByRole('combobox', { name: 'Host' });
  const option = select.locator('option').filter({ hasText: /^\s*host4\.example\.internal( · |\s*$)/ }).first();
  await expect(option).toHaveCount(1, { timeout: 30_000 });
  await select.selectOption({ label: ((await option.textContent()) ?? '').trim() });

  // Open the Services snap-in and load its node, so the node actions (incl. "Recent incidents…") are shown.
  const snapin = page.locator('.bm-snapin').filter({ has: page.locator('.bm-sname', { hasText: /^Services$/ }) });
  await expect(snapin).toBeVisible({ timeout: 30_000 });
  if (!(await snapin.locator('button.bm-node').first().isVisible())) await snapin.locator('.bm-snapin-head').click();
  await snapin.locator('button.bm-node').first().click();
  await expect(page.locator('.bm-result-head')).toContainText('host4.example.internal', { timeout: 60_000 });

  // The node action opens the timeline (it is NOT greyed out — hal has the module).
  const action = page.getByRole('button', { name: /Recent incidents/ });
  await expect(action).toBeEnabled();
  await action.click();

  const panel = page.locator('app-incident-timeline');
  await expect(panel.locator('h3')).toContainText('Recent incidents on host4.example.internal', { timeout: 30_000 });
  // The ring state is said plainly: the eBPF collector is off here, so it is a NAMED not_supported, not an empty list.
  await expect(panel.locator('.it-meta')).toContainText('not_supported', { timeout: 30_000 });
  await expect(panel.locator('.it-meta')).toContainText('eBPF collector is not running');

  // Close it again — it is a view, not a change.
  await panel.getByRole('button', { name: 'Close' }).click();
  await expect(panel).toHaveCount(0);
});
