import { test, expect, Page, request } from '@playwright/test';
import { API_URL, BOOTSTRAP } from './support/env';

/**
 * Deploy → Install hosts and the "Install a host" wizard (docs/kernel-tuning.md, "The same deployment in the UI").
 * Runs against a real hypervisor; nothing is created unless E2E_REAL_DEPLOY=1, because the Review step's dry run
 * already exercises every check the real deploy makes (same backend code as the MCP tool deploy_vm).
 *
 *   V1 nav item → page lists the real deployments with install/agent/finalize state
 *   V2 every step's Next is disabled with its reason until the step is complete
 *   V3 OS step resolves the newest release live from the mirror and pre-fills packages + minimum memory
 *   V4 Network: Suggest proposes free addresses; Check of an address in use blocks Next
 *   V5 Finalize: an unknown playbook name or bad JSON blocks Next, with the reason
 *   V6 Review: the dry run lists the pre-flight checks; Deploy only unlocks when all pass
 *   V7 (E2E_REAL_DEPLOY=1) Deploy → progress → VM created
 */

test.describe.configure({ mode: 'serial' });
test.setTimeout(180_000);

const PREFIX = process.env['E2E_VM_PREFIX'] ?? '10.32.28';
const GATEWAY = process.env['E2E_VM_GATEWAY'] ?? `${PREFIX}.254`;
const HYPERVISOR = process.env['E2E_VM_HOST'] ?? 'PVE Lab';
const NODE = process.env['E2E_VM_NODE'] ?? 'pve1';
const STORAGE = process.env['E2E_VM_STORAGE'] ?? 'local-zfs';
const VLAN = process.env['E2E_VM_VLAN'] ?? '1028';

let catalog: any;
let deployments: any[];

test.beforeAll(async () => {
  const api = await request.newContext({ baseURL: API_URL });
  const token = (await (await api.post('/api/v1/auth/login', { data: BOOTSTRAP })).json()).access_token;
  const auth = { Authorization: `Bearer ${token}` };
  catalog = await (await api.get('/api/v1/provisioning/catalog', { headers: auth })).json();
  deployments = await (await api.get('/api/v1/provisioning/deployments', { headers: auth })).json();
});

const wizard = (page: Page) => page.locator('app-deploy-vm-wizard');
const next = (page: Page) => wizard(page).getByRole('button', { name: 'Next' });
const why = (page: Page) => wizard(page).locator('.bm-dv-why');

async function openWizard(page: Page) {
  await page.goto('/vm-deployments');
  await page.getByRole('button', { name: 'Install a host' }).click();
  await expect(wizard(page).getByRole('heading', { name: 'Target' })).toBeVisible();
}

async function fillTarget(page: Page) {
  const w = wizard(page);
  await w.getByLabel('Hypervisor').selectOption(HYPERVISOR);
  await w.getByLabel('Node').selectOption(NODE);
  await w.getByLabel('Storage').selectOption(STORAGE);
  await w.getByLabel('Bridge').selectOption({ index: 1 });
  await w.getByLabel(/VLAN tag/).fill(VLAN);
}

test('V1 the nav item opens the page and it lists the real deployments', async ({ page }) => {
  // The nav groups pages by workspace; the page sits in Deploy next to Roles & Features.
  await page.goto('/role-deployments');
  await page.getByRole('link', { name: 'Install hosts' }).first().click();
  await expect(page).toHaveURL(/\/vm-deployments/);
  await expect(page.getByRole('heading', { name: 'Install hosts' })).toBeVisible();
  if (!deployments.length) {
    await expect(page.getByText('No deployments yet')).toBeVisible();
    return;
  }
  const first = deployments[0];
  // Newest first; a host deployed twice has a row per deployment, so take the first (most recent) one.
  const row = page.locator('tbody tr', { hasText: first.hostname }).first();
  await expect(row).toBeVisible();
  await expect(row).toContainText(first.status);
  // A deleted VM's row is a named state of its own, with no agent column ("—"), not "not yet".
  const gone = ['vm_deleted', 'cancelled'].includes(first.status);
  if (!gone) { await expect(row).toContainText(first.last_seen_at ? 'reported' : 'not yet'); }
  else { await expect(row).not.toContainText('not yet'); }
});

test('V2–V6 the wizard explains every disabled Next and checks before it creates', async ({ page }) => {
  test.skip(!catalog.vm_hosts.some((h: any) => h.name === HYPERVISOR), `hypervisor ${HYPERVISOR} is not registered`);
  await openWizard(page);
  const w = wizard(page);

  // V2 — Target: Next names the first missing field.
  await expect(next(page)).toBeDisabled();
  // A single hypervisor is preselected, so the first missing field is then the node.
  await expect(why(page)).toHaveText(catalog.vm_hosts.length === 1 ? 'Choose a node' : 'Choose a hypervisor');
  await fillTarget(page);
  await expect(next(page)).toBeEnabled();
  await next(page).click();

  // V3 — OS: Debian's newest release resolved from the mirror, packages pre-filled.
  await expect(why(page)).toHaveText('Choose a distribution');
  await w.getByRole('button', { name: /^Debian/ }).click();
  await expect(w.getByText(/installer found on the mirror/)).toBeVisible({ timeout: 60_000 });
  await expect(w.getByLabel(/^Packages/)).toHaveValue(/fio/);
  await next(page).click();

  // V2 — Machine: an invalid name is refused with the rule; the memory floor of the installer is enforced.
  await w.getByLabel('VM name', { exact: true }).fill('Bad_Name');
  await expect(why(page)).toHaveText(/lowercase letters, digits and dashes/);
  // Next stays focusable (aria-disabled): a click moves the focus to the field that blocks it.
  await next(page).click({ force: true });
  await expect(w.getByLabel('VM name', { exact: true })).toBeFocused();
  await expect(why(page)).toHaveClass(/bm-dv-why--nudged/);
  await w.getByLabel('VM name', { exact: true }).fill('kt-e2e-wizard');
  await w.getByLabel('Memory (MB)').fill('512');
  await expect(why(page)).toHaveText(/Memory must be at least/);
  await w.getByLabel('Memory (MB)').fill('4096');
  await expect(next(page)).toBeEnabled();
  await next(page).click();

  // V4 — Network: an address that is in use (the gateway) blocks Next; Suggest offers free ones.
  await w.getByLabel('Gateway').fill(GATEWAY);
  await w.getByLabel('Address (CIDR)').fill(`${GATEWAY}/24`);
  await w.getByRole('button', { name: 'Check' }).click();
  await expect(w.getByRole('status')).toContainText(/in_use|unknown/, { timeout: 60_000 });
  if ((await w.getByRole('status').textContent())?.includes('in_use')) {
    await expect(next(page)).toBeDisabled();
    await expect(why(page)).toHaveText('This address is in use');
  }
  await w.getByRole('button', { name: 'Suggest' }).click();
  const chip = w.locator('.bm-dv-chip').first();
  await expect(chip).toBeVisible({ timeout: 90_000 });
  await chip.click();
  await expect(w.getByRole('status')).toContainText(/: free/, { timeout: 60_000 });
  await w.getByLabel(/DNS servers/).fill('203.0.113.115');
  await expect(next(page)).toBeEnabled();
  await next(page).click();

  // V5 — Finalize: an unknown playbook and malformed variables are named, not silently ignored.
  await w.getByLabel(/^Playbook/).fill('no-such-runbook-e2e');
  await expect(w.getByText('No stored runbook is called "no-such-runbook-e2e".')).toBeVisible();
  await expect(next(page)).toBeDisabled();
  const rb = catalog.runbooks.find((r: any) => r.name.startsWith('install-'))?.name ?? catalog.runbooks[0]?.name;
  if (rb) {
    await w.getByLabel(/^Playbook/).fill(rb);
    await w.getByLabel(/^Variables/).fill('{not json');
    await expect(why(page)).toHaveText('Variables: not valid JSON');
    await w.getByLabel(/^Variables/).fill('{"e2e": true}');
  }
  await expect(next(page)).toBeEnabled();
  await next(page).click();

  // V6 — Review: the dry run lists the checks; Deploy is enabled exactly when all of them pass.
  const checks = w.locator('.bm-dv-checks li');
  await expect(checks.first()).toBeVisible({ timeout: 90_000 });
  const failed = await w.locator('.bm-dv-checks li.bm-dv-no').count();
  const deploy = w.getByRole('button', { name: /Deploy/ });
  if (failed) {
    await expect(deploy).toBeDisabled();
  } else {
    await expect(deploy).toBeEnabled();
  }
  await expect(w.locator('.bm-dv-checks')).toContainText('address free');

  if (process.env['E2E_REAL_DEPLOY'] === '1' && !failed) {
    // V7 — a real deployment: the VM is created and the progress view takes over.
    await deploy.click();
    await expect(w.getByRole('heading', { name: 'Progress' })).toBeVisible({ timeout: 120_000 });
    await expect(w.locator('.bm-dv-checks li').first()).toHaveClass(/bm-dv-ok/);
  }
  await w.getByRole('button', { name: /Cancel|Close/ }).click();
  await expect(wizard(page)).toHaveCount(0);
});

test('V8 bare metal + golden image with its own sizing + a role: the dry run checks each', async ({ page }) => {
  const img = catalog.images.find((i: any) => i.status === 'ready' && i.volumes?.some((v: any) => ['root', 'var', 'home', 'data'].includes(v.role)));
  test.skip(!img, 'no ready golden image with growable volumes');
  await openWizard(page);
  const w = wizard(page);
  await w.getByLabel('Bare metal').check();
  await w.getByLabel('MAC address').fill('aa:bb:cc:dd:e2:e8');
  await next(page).click();
  await w.getByLabel('Golden image').check();
  await w.locator('select[name="image"]').selectOption(img.name);
  // The shared sizing editor: one value per volume, the last one takes the rest.
  await expect(w.locator('bm-grow-sizing')).toContainText('rest ·');
  await next(page).click();
  await w.getByLabel('Name', { exact: true }).fill('kt-e2e-bare');
  await expect(w.getByLabel('CPU cores')).toHaveCount(0);   // no VM fields for bare metal
  await next(page).click();
  await w.getByLabel('Gateway').fill(GATEWAY);
  await w.getByLabel('Address (CIDR)').fill(`${PREFIX}.250/24`);
  await next(page).click();
  if (catalog.roles.length) {
    await w.getByLabel(/^Roles/).fill(catalog.roles[0].name);
    await w.getByLabel(/^Roles/).press('Enter');
    await expect(w.locator('.bm-dv-chip', { hasText: catalog.roles[0].name })).toBeVisible();
  }
  await next(page).click();
  const checks = w.locator('.bm-dv-checks');
  await expect(checks).toContainText('machine identified by MAC', { timeout: 90_000 });
  await expect(checks).toContainText('volume sizing');
  if (catalog.roles.length) { await expect(checks).toContainText(`role ${catalog.roles[0].name}`); }
  await expect(w.locator('.bm-dv-sum')).toContainText('bare metal · aa:bb:cc:dd:e2:e8');
  await w.getByRole('button', { name: /Cancel/ }).click();
});
