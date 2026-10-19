import { test, expect, Page } from '@playwright/test';
import { api } from './support/routes';
import { settle, watch } from './support/checks';

// The host list and the host page against real enrolled hosts: e2e-deb-1 (Debian 13, systemd container in
// minikube) and, for the Windows-only tab, bossman-wintest. Signed in as the suite admin (storage state).

const LINUX_TABS = ['Overview', 'Services', 'Inventory', 'Management', 'Checks', 'Console', 'Relationships', 'eBPF',
  'Processes', 'Runs', 'Resources', 'Kubernetes'];

async function agentId(name: string): Promise<string | undefined> {
  const ctx = await api();
  const r = await ctx.get('/api/v1/agents');
  const body = await r.json();
  const list: any[] = Array.isArray(body) ? body : body.agents ?? [];
  return list.find((a) => a.name === name)?.id;
}

async function tabNames(page: Page): Promise<string[]> {
  const tabs = page.locator('.bm-host-tabs [role="tab"]');
  await expect(tabs.first()).toBeVisible();
  return (await tabs.allInnerTexts()).map((t) => t.trim());
}

test('the host list shows the enrolled e2e host and opens its page', async ({ page }) => {
  const w = watch(page);
  await page.goto('/hosts');
  await expect(page.getByRole('heading', { name: 'Hosts', level: 1 })).toBeVisible();
  const row = page.getByRole('row').filter({ has: page.getByRole('cell', { name: 'e2e-deb-1', exact: true }) });
  await expect(row).toHaveCount(1);
  // Every row action names what it does (the icon buttons carry the reason as their accessible name).
  await expect(row.getByRole('button', { name: /^Poll now/ })).toBeVisible();
  await expect(row.getByRole('button', { name: 'Delete host' })).toBeVisible();

  await row.getByRole('cell', { name: 'e2e-deb-1', exact: true }).click();
  await expect(page).toHaveURL(/\/hosts\/[0-9a-f-]{36}/);
  await expect(page.getByRole('heading', { name: 'e2e-deb-1', level: 1 }).first()).toBeVisible();
  await settle(page);
  expect(w.consoleErrors, 'console errors on the host page').toEqual([]);
});

test('a Linux host page has the current tabs, and each tab renders its content', async ({ page }) => {
  const id = await agentId('e2e-deb-1');
  test.skip(!id, 'e2e-deb-1 is not enrolled on this instance');
  await page.goto(`/hosts/${id}`);
  expect(await tabNames(page)).toEqual(LINUX_TABS);
  // "Event log" is Windows-only.
  await expect(page.getByRole('tab', { name: 'Event log' })).toHaveCount(0);

  // Overview: live gauges from the agent's metrics.
  await expect(page.getByRole('tabpanel').getByRole('heading', { name: 'Performance' })).toBeVisible({ timeout: 20_000 });

  // Inventory: the facts the agent reported — the OS is named.
  await page.getByRole('tab', { name: 'Inventory' }).click();
  await expect(page.getByRole('tabpanel').getByText(/Debian/).first()).toBeVisible({ timeout: 20_000 });

  // Management: the console tree (Roles & Features, Configuration, …).
  await page.getByRole('tab', { name: 'Management' }).click();
  await expect(page.getByRole('tabpanel').getByText('Roles & Features').first()).toBeVisible({ timeout: 20_000 });

  // A deep link selects the tab it names.
  await page.goto(`/hosts/${id}?tab=resources`);
  await expect(page.getByRole('tab', { name: 'Resources' })).toHaveAttribute('aria-selected', 'true');
  await page.goto(`/hosts/${id}?tab=kubernetes`);
  await expect(page.getByRole('tab', { name: 'Kubernetes' })).toHaveAttribute('aria-selected', 'true');
});

test('a Windows host page adds the Event log tab', async ({ page }) => {
  const id = await agentId('bossman-wintest');
  test.skip(!id, 'no Windows host (bossman-wintest) on this instance');
  await page.goto(`/hosts/${id}`);
  const names = await tabNames(page);
  expect(names).toContain('Event log');
  expect(names.filter((n) => n !== 'Event log')).toEqual(LINUX_TABS);
});

test('on a Windows host, ?tab=kubernetes deep-links to the Kubernetes tab', async ({ page }) => {
  // Regression (fixed): the tab list had no entry for the Windows-only "Event log" tab, which the template inserts
  // BEFORE "Kubernetes", so ?tab=kubernetes on a Windows host opened Event log. The list is now derived per host.
  const id = await agentId('bossman-wintest');
  test.skip(!id, 'no Windows host (bossman-wintest) on this instance');
  await page.goto(`/hosts/${id}?tab=kubernetes`);
  expect(await tabNames(page)).toContain('Event log');
  await expect(page.getByRole('tab', { name: 'Kubernetes' })).toHaveAttribute('aria-selected', 'true', { timeout: 15_000 });
});

test('the topology page mounts its graph', async ({ page }) => {
  await page.goto('/topology');
  await expect(page).toHaveURL(/\/topology/);
  await expect(page.getByRole('heading', { name: /Infrastructure map/ })).toBeVisible();
  // echarts draws to a <canvas>, not DOM text — confirm the chart mounted (not the empty/error state).
  await expect(page.locator('.bm-topo-chart canvas').first()).toBeVisible({ timeout: 30_000 });
});
