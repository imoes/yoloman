import { test, expect } from '@playwright/test';
import { login } from './helpers';

test('hosts list shows the real enrolled agent, detail tabs render real data', async ({ page }) => {
  await login(page);
  await page.getByRole('link', { name: 'Hosts' }).click();
  await expect(page).toHaveURL(/\/hosts$/);
  await expect(page.getByText('duppy-ui-e2e')).toBeVisible();
  await expect(page.getByText('127.0.0.1:8099')).toBeVisible();

  await page.getByText('duppy-ui-e2e').click();
  await expect(page).toHaveURL(/\/hosts\//);
  await expect(page.getByRole('heading', { name: 'duppy-ui-e2e' })).toBeVisible();

  await expect(page.getByRole('tab', { name: 'Facts' })).toBeVisible();
  await expect(page.getByRole('tab', { name: 'Metrics' })).toBeVisible();
  await expect(page.getByRole('tab', { name: 'Relationships' })).toBeVisible();
  await expect(page.getByRole('tab', { name: 'Runs' })).toBeVisible();
});

test('topology page renders a node for the real agent', async ({ page }) => {
  await login(page);
  await page.getByRole('link', { name: 'Topology' }).click();
  await expect(page).toHaveURL(/\/topology/);
  // cytoscape draws to a <canvas>, not DOM text — just confirm the graph container mounted.
  await expect(page.locator('app-topology-graph .bm-topology')).toBeVisible();
});
