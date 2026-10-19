import { test, expect } from '@playwright/test';
import { apiAs, ok } from './support/deploy-scenario';

/**
 * The patch-ring form with its dry-run preview (UX concept #5). A patch ring installs Windows updates across the
 * fleet in ordered waves; the form plans it as a dry-run first and shows the check page — how many Windows hosts were
 * kept, the waves, and which hosts were skipped with the reason — before anything is started. Nothing installs here:
 * the ring is created pending and dry-run, then deleted in cleanup.
 */
test.setTimeout(120_000);

let createdId = '';

test.afterAll(async () => {
  if (!createdId) return;
  const api = await apiAs('admin');
  await api.delete(`/api/v1/rollouts/${createdId}`).catch(() => undefined);
});

test('New patch ring plans a dry-run and shows the check page', async ({ page }) => {
  const api = await apiAs('admin');
  const agents = await ok<any>(api.get('/api/v1/agents'), 'agents');
  const list: any[] = Array.isArray(agents) ? agents : agents.agents ?? [];
  test.skip(!list.find((a) => a.name === 'bossman-wintest'), 'the Windows test host is not enrolled here');

  await page.setViewportSize({ width: 1500, height: 1000 });
  await page.goto('/rollouts');
  await page.getByRole('button', { name: /New patch ring/ }).click();

  const form = page.locator('.bm-form').filter({ hasText: 'New patch ring' });
  await expect(form).toBeVisible({ timeout: 30_000 });
  const name = `e2e patch ring ${Date.now()}`;
  await form.locator('input').first().fill(name);
  // Scope → Single host → bossman-wintest.
  await form.locator('select').filter({ hasText: 'All hosts' }).selectOption('host');
  await form.locator('select').last().selectOption({ label: 'bossman-wintest' });
  // Dry-run is on by default; plan it.
  await form.getByRole('button', { name: /Plan \(dry-run\)/ }).click();

  const preview = page.locator('.bm-preview');
  await expect(preview).toContainText(`Patch ring planned: ${name}`, { timeout: 30_000 });
  await expect(preview).toContainText(/1 Windows host\(s\) kept/);
  await expect(preview).toContainText(/dry-run — nothing installs/);

  // The ring is now in the list, pending + dry-run, with a Start button (nothing has run).
  const card = page.locator('.bm-card').filter({ hasText: name }).filter({ hasText: '(dry-run)' });
  await expect(card).toBeVisible();
  await expect(card.getByRole('button', { name: 'Start' })).toBeVisible();

  // Capture the id for cleanup (newest pending ring with this name).
  const rollouts = await ok<any[]>(api.get('/api/v1/rollouts'), 'rollouts');
  createdId = (rollouts.find((r) => r.name === name)?.id) ?? '';
  expect(createdId).not.toBe('');
});
