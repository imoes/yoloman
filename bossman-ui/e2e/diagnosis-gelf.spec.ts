import { test, expect } from '@playwright/test';
import { apiAs, ok } from './support/deploy-scenario';

/**
 * Send a diagnosis to Graylog from the UI, and show the GELF target in Settings (UX concept #4). The target is
 * env-based and read-only; the Settings card reflects it, and a diagnosis's "Send to Graylog" button is greyed up
 * front with the reason when none is set, or sends (and reports how many messages over which transport) when one is.
 *
 * In the dev stack BOSSMAN_GELF_HOST=graylog, so this exercises the configured path. Nothing about the diagnosis
 * changes; the messages are one per finding and per evidence, tagged with the diagnosis id.
 */
test.setTimeout(120_000);

test('Settings shows the Graylog target', async ({ page }) => {
  await page.goto('/settings');
  const card = page.locator('mat-card').filter({ hasText: 'Graylog (GELF) target' });
  await expect(card).toBeVisible({ timeout: 30_000 });
  // The dev stack points at graylog:12201/udp; the card states it plainly (or says none is configured).
  await expect(card).toContainText(/Configured: .+:\d+ over (UDP|TCP)|No GELF target configured/);
});

test('A diagnosis is sent to Graylog from its permalink', async ({ page }) => {
  const halId = '9900fc29-baa9-405c-a0da-7174f3006537';
  const api = await apiAs('admin');
  const list = await ok<{ items: Array<{ id: string }> }>(api.get(`/api/v1/agents/${halId}/diagnoses?limit=1`), 'list diagnoses');
  test.skip(list.items.length === 0, 'no saved diagnosis for hal');
  const graylog = await ok<{ configured: boolean }>(api.get('/api/v1/system/graylog'), 'graylog settings');

  await page.goto(`/diagnoses/${list.items[0].id}`);
  const panel = page.locator('app-diagnosis-panel');
  await expect(panel.locator('.dg-summary')).toBeVisible({ timeout: 30_000 });
  const send = panel.getByRole('button', { name: /Send to Graylog/ });

  if (graylog.configured) {
    await expect(send).toBeEnabled();
    await send.click();
    await expect(panel.locator('.dg-top-actions')).toContainText(/Sent \d+ GELF message/, { timeout: 30_000 });
  } else {
    // No target: the action is greyed up front with the reason, never a silent no-op.
    await expect(send).toBeDisabled();
    await expect(send).toHaveAttribute('title', /no graylog target/i);
  }
});
