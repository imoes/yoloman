import { test, expect, Page, APIRequestContext } from '@playwright/test';
import {
  RUN, agentId, apiAs, callTool, deploymentByName, ok, pageAs, retireTagged, setYolo, tag, until, why, withLock, yolo,
} from './support/deploy-scenario';

/**
 * The SCCM-like deployment pipeline (Deploy → Roles & Features, docs/role-deployments.md) end to end against the
 * enrolled systemd test hosts — real package installs, real drift, real approvals.
 *
 *   B1 the form refuses with reasons      B2 host → preview → create → compliant     B3 other family → not_applicable
 *   B4 four-eyes approval                 B5 pilot gates the main phase              B6 stale preview → 409 message
 *   B7 drift → reason → correct           B8 read-only host → blocked                B9 stop managing vs uninstall
 *   B10 host wizard → deployment          B11 rollouts                               B12 software compliance
 *   B13 scheduler                         B14 change proposals
 *
 * Catalog items are chosen from what the package e2e measured compliant on Debian 13 in a container
 * (configs/package_e2e_bossman_results.jsonl): earlyoom, beanstalkd, memlockd, dhcp-helper — all Debian-only,
 * which also makes them the not-applicable probe on AlmaLinux.
 */

test.describe.configure({ mode: 'serial' });
test.setTimeout(420_000);

let api: APIRequestContext;
let hosts: Record<string, string> = {};
const artifacts: Record<string, string> = {};

async function artifactId(name: string): Promise<string> {
  if (!artifacts[name]) {
    const { artifacts: list } = await ok<any>(api.get('/api/v1/role-artifacts'), 'artifacts');
    const a = list.find((x: any) => x.name === name);
    expect(a, `artifact ${name} is published`).toBeTruthy();
    artifacts[name] = a.id;
  }
  return artifacts[name];
}

const card = (page: Page, name: string) => page.locator(`mat-card[data-deployment="${name}"]`);
const targetRow = (page: Page, name: string, host: string) => card(page, name).locator(`tr[data-host="${host}"]`);

/** Fill the "New deployment" form (host target unless told otherwise). */
async function fillForm(page: Page, o: { name: string; artifact: string; type?: string; target?: string; pilot?: string }) {
  await page.getByLabel('Name', { exact: true }).fill(o.name);
  await page.getByLabel('Role or feature').selectOption(await artifactId(o.artifact));
  await page.getByLabel('Target type').selectOption(o.type ?? 'host');
  if (o.target) {
    const label = { host: 'Host', group: 'Host group', ou: 'OU', site: 'Site' }[o.type ?? 'host']!;
    await page.getByLabel(label, { exact: true }).selectOption(o.target);
  }
  if (o.pilot) await page.getByLabel('Pilot phase').selectOption(o.pilot);
}

async function previewAndCreate(page: Page, expectStatus = /Deployment created\./) {
  await page.getByRole('button', { name: 'Preview' }).click();
  await expect(page.locator('.rd-preview')).toBeVisible();
  await page.getByRole('button', { name: 'Create deployment' }).click();
  await expect(page.locator('.rd-msg')).toHaveText(expectStatus, { timeout: 30_000 });
}

/** Click "Detect now" until the host's row reaches `state` (the worker may hold the deployment lock meanwhile). */
async function detectUntil(page: Page, name: string, host: string, state: string | RegExp, timeout = 300_000) {
  const row = targetRow(page, name, host);
  await expect.poll(async () => {
    const btn = card(page, name).getByRole('button', { name: /Detect now/ });
    if (await btn.isEnabled()) await btn.click();
    await expect(page.locator('.rd-msg')).toBeVisible({ timeout: 120_000 }).catch(() => undefined);
    await page.waitForTimeout(1500);
    return row.getAttribute('data-state');
  }, { message: `${host} reaches ${state} in ${name}`, timeout, intervals: [3_000] })
    .toMatch(typeof state === 'string' ? new RegExp(`^${state}$`) : state);
}

async function confirmNext(page: Page) {
  page.once('dialog', (d) => d.accept());
}

async function sh(agent: string, cmd: string): Promise<{ rc: number; stdout: string }> {
  const r = await callTool(api, agent, 'command', { argv: ['sh', '-c', cmd] });
  const data = r.result?.data ?? r.result ?? {};
  return { rc: data.rc ?? -1, stdout: String(data.stdout ?? '') };
}

test.beforeAll(async () => {
  api = await apiAs('admin');
  for (const h of ['e2e-deb-1', 'e2e-deb-2', 'e2e-deb-ro', 'e2e-rh-1']) hosts[h] = await agentId(api, h);
});

test.afterAll(async () => {
  // Everything this run created is retired (stopped managing); the software is removed where the scenario
  // installed it so the next run exercises the install path again.
  await retireTagged(api, 'uninstall').catch(() => undefined);
  await retireTagged(api, 'unmanage').catch(() => undefined);
  await api.dispose();
});

test('B1 Preview and Create refuse with a reason until the form is complete, and a changed field drops the preview', async ({ page }) => {
  await page.goto('/role-deployments');
  const previewBtn = page.getByRole('button', { name: 'Preview' });
  const createBtn = page.getByRole('button', { name: 'Create deployment' });
  await expect(previewBtn).toBeDisabled();
  expect(await why(previewBtn)).toBe('Name the deployment first');
  await page.getByLabel('Name', { exact: true }).fill(tag('b1'));
  expect(await why(previewBtn)).toBe('Select a role or feature first');
  await page.getByLabel('Role or feature').selectOption(await artifactId('catalog__earlyoom'));
  expect(await why(previewBtn)).toBe('Select a host first');
  await page.getByLabel('Target type').selectOption('group');
  expect(await why(previewBtn)).toBe('Select a host group first');
  await page.getByLabel('Target type').selectOption('ou');
  expect(await why(previewBtn)).toBe('Select a OU first');
  await page.getByLabel('Target type').selectOption('host');
  await page.getByLabel('Host', { exact: true }).selectOption(hosts['e2e-deb-1']);
  await expect(previewBtn).toBeEnabled();
  await expect(createBtn).toBeDisabled();
  expect(await why(createBtn)).toMatch(/^Preview first/);

  await previewBtn.click();
  await expect(page.locator('.rd-preview')).toContainText('1 affected host');
  await expect(page.locator('.rd-preview')).toContainText('1/1 applicable');
  await expect(page.locator('.rd-msg')).toHaveText('Preview is current.');
  await expect(createBtn).toBeEnabled();

  // Any field the preview locked drops it — and its "current" message with it.
  await page.getByLabel('Pilot phase').selectOption('on');
  await expect(page.locator('.rd-preview')).toHaveCount(0);
  await expect(page.locator('.rd-msg')).toHaveCount(0);
  await expect(createBtn).toBeDisabled();
  expect(await why(createBtn)).toMatch(/^Preview first/);
});

const B2 = tag('b2-earlyoom-deb1');

test('B2 a host target installs a catalog role and Detect now reports it compliant', async ({ page }) => {
  await page.goto('/role-deployments');
  await fillForm(page, { name: B2, artifact: 'catalog__earlyoom', target: hosts['e2e-deb-1'] });
  await page.getByRole('button', { name: 'Preview' }).click();
  await expect(page.locator('.rd-preview')).toContainText('1/1 applicable');
  await expect(page.locator('.rd-preview')).toContainText('Ready to deploy');
  await page.getByRole('button', { name: 'Create deployment' }).click();
  await expect(page.locator('.rd-msg')).toHaveText('Deployment created.', { timeout: 30_000 });
  await expect(card(page, B2).locator('.rd-status')).toHaveText('Active');
  await expect(card(page, B2)).toContainText('host e2e-deb-1');
  await detectUntil(page, B2, 'e2e-deb-1', 'compliant');
  expect((await sh(hosts['e2e-deb-1'], 'dpkg-query -W -f=\'${Status}\' earlyoom')).stdout).toContain('install ok installed');
});

test('B3 an item the catalog marks unavailable on AlmaLinux is not applicable, and says why', async ({ page }) => {
  const name = tag('b3-apparmor-rh1');
  await page.goto('/role-deployments');
  // A Debian-only item is applicable on AlmaLinux only by borrowing the Debian package name — said apart.
  await fillForm(page, { name, artifact: 'catalog__earlyoom', target: hosts['e2e-rh-1'] });
  await page.getByRole('button', { name: 'Preview' }).click();
  await expect(page.locator('.rd-preview .rd-sub')).toContainText('e2e-rh-1 (applicable by substitution): No redhat entry in the catalog');

  // AppArmor: the catalog states it does not exist on RHEL rebuilds → not applicable, with the curated reason.
  await page.getByLabel('Role or feature').selectOption(await artifactId('catalog__apparmor'));
  await page.getByRole('button', { name: 'Preview' }).click();
  await expect(page.locator('.rd-preview')).toContainText('0/1 applicable');
  await expect(page.locator('.rd-preview .rd-na')).toHaveText('e2e-rh-1: RHEL and its rebuilds ship SELinux; AppArmor is not packaged.');
  await page.getByRole('button', { name: 'Create deployment' }).click();
  await expect(page.locator('.rd-msg')).toHaveText('Deployment created.');
  await detectUntil(page, name, 'e2e-rh-1', 'not_applicable', 120_000);
  await expect(targetRow(page, name, 'e2e-rh-1').locator('.rd-reason')).toHaveText('RHEL and its rebuilds ship SELinux; AppArmor is not packaged.');
});

test('B7 drift on the host is reported with its reason, and Correct drift makes it compliant again', async ({ page }) => {
  await page.goto('/role-deployments');
  await expect(card(page, B2)).toBeVisible();
  const correct = card(page, B2).getByRole('button', { name: /Correct drift/ });
  await expect(correct).toBeDisabled();
  expect(await why(correct)).toMatch(/Nothing to correct/);

  // Change the managed config behind Bossman's back (a tool call on the host, as an operator with a shell would).
  const drift = await sh(hosts['e2e-deb-1'],
    `sed -i 's/^MEMORY_MIN_PERCENT=.*/MEMORY_MIN_PERCENT="33"/' /etc/default/earlyoom && grep ^MEMORY_MIN_PERCENT= /etc/default/earlyoom`);
  expect(drift.stdout).toContain('MEMORY_MIN_PERCENT="33"');

  await detectUntil(page, B2, 'e2e-deb-1', 'noncompliant', 120_000);
  await expect(targetRow(page, B2, 'e2e-deb-1').locator('.rd-reason')).toHaveText('drift detected in: Render configuration');
  await expect(correct).toBeEnabled();
  await confirmNext(page);
  await correct.click();
  await expect(page.locator('.rd-msg')).toHaveText('Drift correction completed.', { timeout: 180_000 });
  await detectUntil(page, B2, 'e2e-deb-1', 'compliant', 180_000);
  expect((await sh(hosts['e2e-deb-1'], 'grep ^MEMORY_MIN_PERCENT= /etc/default/earlyoom')).stdout).toContain('MEMORY_MIN_PERCENT="10"');
});

test('B8 a read-only host is blocked, with the reason', async ({ page }) => withLock('deb-ro-gate', async () => {
  const name = tag('b8-earlyoom-ro');
  await page.goto('/role-deployments');
  await fillForm(page, { name, artifact: 'catalog__earlyoom', target: hosts['e2e-deb-ro'] });
  await previewAndCreate(page);
  await detectUntil(page, name, 'e2e-deb-ro', 'blocked', 180_000);
  await expect(targetRow(page, name, 'e2e-deb-ro').locator('.rd-reason')).toContainText(/read-only|write/i);
  // Blocked counts as something to correct — the button says so instead of hiding.
  await expect(card(page, name).getByRole('button', { name: /Correct drift/ })).toBeEnabled();
}));

test('B9 Stop managing leaves the software; Uninstall removes it; an authored role cannot be uninstalled, and says why', async ({ page }) => {
  await page.goto('/role-deployments');
  // Stop managing: retired, package still there.
  await confirmNext(page);
  await card(page, B2).getByRole('button', { name: 'Stop managing' }).click();
  await expect(page.locator('.rd-msg')).toHaveText('Deployment retired; software was left installed.');
  await expect(card(page, B2).locator('.rd-status')).toHaveText('Retired');
  await expect(card(page, B2)).toContainText('Retired — nothing is managed any more.');
  expect((await sh(hosts['e2e-deb-1'], 'dpkg-query -W -f=\'${Status}\' earlyoom')).stdout).toContain('install ok installed');

  // Uninstall: a fresh deployment of the same catalog role (already installed → compliant at once), then Uninstall.
  const again = tag('b9-earlyoom-uninstall');
  await fillForm(page, { name: again, artifact: 'catalog__earlyoom', target: hosts['e2e-deb-1'] });
  await previewAndCreate(page);
  await detectUntil(page, again, 'e2e-deb-1', 'compliant');
  const uninstall = card(page, again).getByRole('button', { name: 'Uninstall' });
  await expect(uninstall).toBeEnabled();
  await confirmNext(page);
  await uninstall.click();
  await expect(page.locator('.rd-msg')).toHaveText('Deployment uninstalled and retired.', { timeout: 120_000 });
  await until(async () => !(await sh(hosts['e2e-deb-1'], 'dpkg-query -W -f=\'${Status}\' earlyoom 2>&1')).stdout.includes('install ok installed'),
    'earlyoom is removed from e2e-deb-1', 60_000);

  // An authored role has no inverse: Uninstall is greyed with the reason; the API refuses the same way.
  const roleName = `e2e_b9_role_${RUN}`;
  const rb = await ok<any>(api.post('/api/v1/runbooks', { data: {
    folder: `e2e/${RUN}`,
    playbook: `role: ${roleName}\ndescription: e2e authored role\ntasks:\n  - name: marker file\n    copy:\n      dest: /tmp/${roleName}.txt\n      content: "e2e"\n`,
  } }), 'save authored role');
  try {
    const plan = (await ok<any>(api.get('/api/v1/role-artifacts'), 'artifacts')).artifacts.find((a: any) => a.name === roleName);
    expect(plan, 'saving the role published an artifact').toBeTruthy();
    artifacts[roleName] = plan.id;
    const authored = tag('b9-authored');
    await page.reload();
    await fillForm(page, { name: authored, artifact: roleName, target: hosts['e2e-deb-1'] });
    await previewAndCreate(page);
    const greyed = card(page, authored).getByRole('button', { name: 'Uninstall' });
    await expect(greyed).toBeDisabled();
    expect(await why(greyed)).toMatch(/is not a catalog role — Bossman knows no uninstall for it; Stop managing leaves it installed/);
    const dep = await deploymentByName(api, authored);
    await until(async () => (await deploymentByName(api, authored)).targets.some((t: any) => t.state !== 'pending'),
      'the authored role leaves pending', 180_000).catch(() => undefined);
    const refused = await api.post(`/api/v1/role-deployments/${dep.id}/retire`, { data: { behavior: 'uninstall' } });
    expect(refused.status()).toBe(422);
    expect((await refused.json()).detail).toContain('catalog-backed uninstall');
    await confirmNext(page);
    await card(page, authored).getByRole('button', { name: 'Stop managing' }).click();
    await expect(card(page, authored).locator('.rd-status')).toHaveText('Retired');
  } finally {
    await api.delete(`/api/v1/runbooks/${rb.id}`);
    await sh(hosts['e2e-deb-1'], `rm -f /tmp/${roleName}.txt`);
  }
});

test('B4 four-eyes: the creator sees Approve greyed with the reason; a second administrator approves', async ({ page, browser }) => {
  const name = tag('b4-memlockd-deb2');
  await page.goto('/role-deployments');

  // Policy: an all-hosts target always needs approval — the box is ticked and cannot be unticked, and says why.
  await page.getByLabel('Name', { exact: true }).fill(tag('b4-global-preview-only'));
  await page.getByLabel('Role or feature').selectOption(await artifactId('catalog__memlockd'));
  await page.getByLabel('Target type').selectOption('global');
  const box = page.getByLabel('Require approval by a second administrator');
  await expect(box).toBeChecked();
  await expect(box).toBeDisabled();
  expect(await why(box)).toMatch(/Policy requires a second administrator/);
  await page.getByRole('button', { name: 'Preview' }).click();
  await expect(page.locator('.rd-preview')).toContainText('Approval required by policy');
  // (not created: a global install would touch every enrolled machine, including real servers)

  await fillForm(page, { name, artifact: 'catalog__memlockd', target: hosts['e2e-deb-2'] });
  await expect(box).toBeEnabled();
  await box.check();
  await page.getByRole('button', { name: 'Preview' }).click();
  await expect(page.locator('.rd-preview')).toContainText('Approval requested');
  await page.getByRole('button', { name: 'Create deployment' }).click();
  await expect(page.locator('.rd-msg')).toHaveText('Deployment created and awaiting approval.');
  const mine = card(page, name);
  await expect(mine.locator('.rd-status')).toHaveText('Pending approval');
  const approve = mine.getByRole('button', { name: 'Approve' });
  await expect(approve).toBeDisabled();
  expect(await why(approve)).toBe('Four-eyes: another administrator must approve — you created this deployment');
  const detect = mine.getByRole('button', { name: /Detect now/ });
  await expect(detect).toBeDisabled();
  expect(await why(detect)).toMatch(/approved/);

  const other = await pageAs(browser, 'admin2');
  try {
    await other.page.goto('/role-deployments');
    const theirs = card(other.page, name);
    await expect(theirs.getByRole('button', { name: 'Approve' })).toBeEnabled();
    await theirs.getByRole('button', { name: 'Approve' }).click();
    await expect(other.page.locator('.rd-msg')).toHaveText('Deployment approved.');
    await expect(theirs.locator('.rd-status')).toHaveText('Active');
    await expect(theirs).toContainText('approved by ui-e2e-admin2');
  } finally {
    await other.ctx.close();
  }
  await page.reload();
  await detectUntil(page, name, 'e2e-deb-2', 'compliant');
});

test('B5 a pilot on a two-host group: the main phase waits until the pilot has been compliant for 30 s', async ({ page }) => {
  const group = await ok<any>(api.post('/api/v1/host-groups', { data: { name: tag('b5-group'), description: 'e2e pilot' } }), 'group');
  try {
    await ok(api.put(`/api/v1/host-groups/${group.id}/members`, { data: { agent_ids: [hosts['e2e-deb-1'], hosts['e2e-deb-2']] } }), 'members');
    const name = tag('b5-beanstalkd-pilot');
    await page.goto('/role-deployments');
    await fillForm(page, { name, artifact: 'catalog__beanstalkd', type: 'group', target: group.id, pilot: 'on' });
    await page.getByRole('button', { name: 'Preview' }).click();
    await expect(page.locator('.rd-preview')).toContainText('2 affected hosts');
    await expect(page.locator('.rd-preview')).toContainText('Pilot enabled');
    await page.getByRole('button', { name: 'Create deployment' }).click();
    await expect(page.locator('.rd-msg')).toHaveText('Deployment created.');

    const dep = await deploymentByName(api, name);
    const pilot = dep.targets.find((t: any) => t.phase === 'pilot');
    const main = dep.targets.find((t: any) => t.phase === 'main');
    expect(pilot && main, 'one pilot target and one main target').toBeTruthy();
    await detectUntil(page, name, pilot.host, 'compliant');
    // Right after the pilot converged the main host is still untouched — and the row says why.
    const mainRow = targetRow(page, name, main.host);
    await expect(mainRow).toHaveAttribute('data-state', 'pending');
    await expect(mainRow.locator('.rd-reason')).toHaveText(/waiting for the pilot host to (stay compliant for 30 s|become compliant)/);
    const pilotDoneAt = Date.now();
    await detectUntil(page, name, main.host, 'compliant', 300_000);
    const applied = (await deploymentByName(api, name)).targets.find((t: any) => t.phase === 'main').applied_at;
    expect(new Date(applied).getTime() - pilotDoneAt, 'main applied only after the 30 s stabilisation').toBeGreaterThan(20_000);
  } finally {
    await retireTagged(api, 'uninstall').catch(() => undefined);
    await api.delete(`/api/v1/host-groups/${group.id}`);
  }
});

test('B6 a membership change between preview and create is refused with "preview again"', async ({ page }) => {
  const group = await ok<any>(api.post('/api/v1/host-groups', { data: { name: tag('b6-group'), description: 'e2e stale preview' } }), 'group');
  try {
    await ok(api.put(`/api/v1/host-groups/${group.id}/members`, { data: { agent_ids: [hosts['e2e-deb-1']] } }), 'members');
    await page.goto('/role-deployments');
    await fillForm(page, { name: tag('b6-stale'), artifact: 'catalog__earlyoom', type: 'group', target: group.id });
    await page.getByRole('button', { name: 'Preview' }).click();
    await expect(page.locator('.rd-preview')).toContainText('1 affected host');
    await ok(api.put(`/api/v1/host-groups/${group.id}/members`, { data: { agent_ids: [hosts['e2e-deb-1'], hosts['e2e-deb-2']] } }), 'grow');
    await page.getByRole('button', { name: 'Create deployment' }).click();
    await expect(page.locator('.rd-msg.error')).toHaveText('target membership changed since preview; preview again');
    // The stale preview is gone, so Create is greyed until the operator previews again.
    await expect(page.locator('.rd-preview')).toHaveCount(0);
    expect(await why(page.getByRole('button', { name: 'Create deployment' }))).toMatch(/^Preview first/);
    expect(await deploymentByName(api, tag('b6-stale'))).toBeUndefined();
  } finally {
    await api.delete(`/api/v1/host-groups/${group.id}`);
  }
});

test('B10 the host Add-roles wizard creates a deployment that /role-deployments shows', async ({ page }) => {
  const pkg = 'dhcp-helper';
  await page.goto(`/hosts/${hosts['e2e-deb-2']}?tab=management`);
  await page.locator('.bm-mmc-node', { hasText: 'Roles & Features' }).click();
  const open = page.getByRole('button', { name: /Add roles and features/ });
  await expect(open).toBeEnabled({ timeout: 60_000 });
  await open.click();
  const wz = page.locator('app-add-roles-wizard');
  await expect(wz.getByRole('heading', { name: 'Before you begin' })).toBeVisible();
  await wz.getByRole('button', { name: 'Next' }).click();
  await wz.getByPlaceholder('Search roles…').fill(pkg);
  const roleRow = wz.locator('.bm-wz-mrole').first();
  await roleRow.click();
  await roleRow.locator('mat-checkbox input').check();
  // Configure step(s) until Confirmation.
  const confirmation = wz.getByRole('heading', { name: 'Confirmation' });
  for (let i = 0; i < 6 && !(await confirmation.isVisible()); i++) {
    const heading = await wz.locator('h2').innerText();
    await wz.getByRole('button', { name: 'Next' }).click();
    await expect(wz.locator('h2')).not.toHaveText(heading);
  }
  await expect(wz.getByRole('heading', { name: 'Confirmation' })).toBeVisible();
  await wz.getByRole('button', { name: 'Install' }).click();
  await expect(wz.getByRole('heading', { name: 'Results' })).toBeVisible();
  await expect(wz.getByRole('button', { name: 'Close' })).toBeVisible({ timeout: 240_000 });
  await wz.getByRole('button', { name: 'Close' }).click();

  const name = 'Roles & Features — e2e-deb-2';
  await page.goto('/role-deployments');
  const dep = page.locator('mat-card.rd-deployment').filter({ hasText: name }).filter({ hasText: /Dhcp/i }).first();
  await expect(dep).toBeVisible();
  await expect(dep.locator('.rd-status')).toHaveText('Active');
  await expect(dep).toContainText('host e2e-deb-2');
  // Cleanup through the same page: Uninstall (a catalog role).
  page.once('dialog', (d) => d.accept());
  await dep.getByRole('button', { name: 'Uninstall' }).click();
  await expect(page.locator('.rd-msg')).toHaveText(/uninstalled and retired/, { timeout: 120_000 });
});

test('B11 a rollout runs canary → waves → done, and a running one can be aborted', async ({ page }) => {
  const group = await ok<any>(api.post('/api/v1/host-groups', { data: { name: tag('b11-group'), description: 'e2e rollout' } }), 'group');
  const runbook = await ok<any>(api.post('/api/v1/runbooks', { data: { folder: `e2e/${RUN}`,
    playbook: `name: e2e_b11_${RUN}\ntasks:\n  - name: say hello\n    debug:\n      msg: hello\n` } }), 'runbook');
  const created: string[] = [];
  try {
    await ok(api.put(`/api/v1/host-groups/${group.id}/members`, { data: { agent_ids: [hosts['e2e-deb-1'], hosts['e2e-deb-2']] } }), 'members');
    await page.goto('/rollouts');
    const make = async (name: string, wait: number) => {
      await page.getByRole('button', { name: 'New rollout' }).click();
      const form = page.locator('.bm-form');
      await form.getByLabel(/^Name/).fill(name);
      await form.getByLabel(/^Runbook\ \(upgrade\)/).selectOption(`e2e_b11_${RUN}`);
      await form.getByLabel(/^Scope/).selectOption('group');
      await form.getByLabel(/^Target/).selectOption(group.id);
      await form.getByLabel(/^Waves\ \(strategy\)/).fill('1, rest');
      await form.getByLabel(/^Health\-gate\ wait\ \(s\)/).fill(String(wait));
      await form.getByRole('button', { name: 'Create' }).click();
      await expect(form).toHaveCount(0);
      const rc = page.locator('.bm-card').filter({ hasText: name });
      await expect(rc).toContainText('2 wave(s)');
      return rc;
    };
    const done = await make(tag('b11-rollout'), 0);
    created.push(tag('b11-rollout'));
    await done.getByRole('button', { name: 'Start' }).click();
    await expect(done.locator('.bm-status')).toHaveText(/done|succeeded|completed/, { timeout: 180_000 });
    await expect(done.locator('.bm-wave--done')).toHaveCount(2);

    const slow = await make(tag('b11-abort'), 120);
    created.push(tag('b11-abort'));
    await slow.getByRole('button', { name: 'Start' }).click();
    await expect(slow.locator('.bm-status')).toHaveText('running', { timeout: 60_000 });
    await slow.getByRole('button', { name: 'Abort' }).click();
    await expect(slow.locator('.bm-status')).toHaveText(/abort/, { timeout: 60_000 });
  } finally {
    const list = await ok<any[]>(api.get('/api/v1/rollouts'), 'rollouts');
    for (const r of list) if (created.includes(r.name)) await api.delete(`/api/v1/rollouts/${r.id}`);
    await api.delete(`/api/v1/runbooks/${runbook.id}`);
    await api.delete(`/api/v1/host-groups/${group.id}`);
  }
});

test('B12 software compliance: a required and a forbidden package are evaluated per host', async ({ page }) => {
  const name = tag('b12-rule');
  await page.goto('/compliance');
  await page.getByRole('button', { name: 'New rule' }).click();
  const form = page.locator('.bm-form');
  await form.getByLabel(/^Name/).fill(name);
  await form.getByLabel(/^Scope/).selectOption('host');
  await form.getByLabel(/^Target/).selectOption(hosts['e2e-deb-1']);
  await form.getByLabel(/Required packages/).fill('bash');
  await form.getByLabel(/Forbidden packages/).fill('telnetd-e2e-never-installed\nbash');
  await form.getByRole('button', { name: 'Create' }).click();
  const rule = page.locator('.bm-card').filter({ hasText: name });
  await expect(rule).toBeVisible();
  try {
    await rule.getByRole('button', { name: 'Evaluate' }).click();
    const results = rule.locator('.bm-results');
    await expect(results).toBeVisible({ timeout: 60_000 });
    await expect(results).toContainText('e2e-deb-1');
    // bash is installed: required satisfied, forbidden violated → the host is out of policy, naming bash.
    await expect(results).toContainText(/bash/);
  } finally {
    const rules = await ok<any[]>(api.get('/api/v1/compliance-rules'), 'rules');
    for (const r of rules) if (r.name === name) await api.delete(`/api/v1/compliance-rules/${r.id}`);
  }
});

test('B13 scheduler: an invalid cron is refused with the error; a valid job runs on demand', async ({ page }) => {
  const name = tag('b13-job');
  const runbook = await ok<any>(api.post('/api/v1/runbooks', { data: { folder: `e2e/${RUN}`,
    playbook: `name: e2e_b13_${RUN}\ntasks:\n  - name: say hello\n    debug:\n      msg: hello\n` } }), 'runbook');
  try {
    await page.goto('/scheduler');
    await page.getByRole('button', { name: 'New scheduled job' }).click();
    const form = page.locator('.bm-form');
    await form.getByLabel(/^Name/).fill(name);
    await form.getByLabel(/^Cron/).fill('61 25 * * *');
    await form.getByLabel(/^Runbook/).selectOption(`e2e_b13_${RUN}`);
    await form.getByLabel(/^Scope/).selectOption('host');
    await form.getByLabel(/^Target/).selectOption(hosts['e2e-deb-1']);
    await form.getByRole('button', { name: 'Create' }).click();
    await expect(form.locator('.bm-err')).toHaveText("invalid cron expression '61 25 * * *': minute: '61' is outside 0-59");
    await form.getByLabel(/^Cron/).fill('0 3 * * 0');
    await form.getByRole('button', { name: 'Create' }).click();
    await expect(form).toHaveCount(0);
    const row = page.locator('tr').filter({ hasText: name });
    await expect(row).toContainText('0 3 * * 0');
    await row.getByRole('button', { name: 'Run now' }).click();
    await expect(row.locator('.bm-status')).not.toHaveText('—', { timeout: 120_000 });
    await expect(row.locator('.bm-status')).toHaveText(/ok|succeeded|success|changed/i);
  } finally {
    const jobs = await ok<any[]>(api.get('/api/v1/scheduled-jobs'), 'jobs');
    for (const j of jobs) if (j.name === name) await api.delete(`/api/v1/scheduled-jobs/${j.id}`);
    await api.delete(`/api/v1/runbooks/${runbook.id}`);
  }
});

test('B14 change proposals: with YOLO off a config apply files a proposal; approve applies it, reject keeps it out', async ({ page }) => withLock('yolo', async () => {
  const before = await yolo(api);
  if (before) await setYolo(api, false);
  const token = await ok<any>(api.post('/api/v1/api-tokens', { data: { name: tag('b14-mcp') } }), 'api token');
  const file = `/tmp/e2e-b14-${RUN}.conf`;
  await sh(hosts['e2e-deb-1'], `printf 'alpha = 1\\n' > ${file}`);
  const mcp = async (values: Record<string, string>) => mcpCall(token.token ?? token.raw ?? token.access_token, 'set_host_config',
    { host: 'e2e-deb-1', path: file, values, config_format: 'keyvalue', separator: ' = ', dry_run: false });
  try {
    const filed = await mcp({ alpha: '2' });
    expect(filed.proposed, 'with YOLO off the apply is filed, not written').toBe(true);
    expect((await sh(hosts['e2e-deb-1'], `cat ${file}`)).stdout).toContain('alpha = 1');

    await page.goto('/change-proposals');
    await page.locator('.pr-segbtn', { hasText: /^Pending$/ }).click();
    const row = page.locator('.pr-row').filter({ hasText: `Set ${file} on e2e-deb-1` }).first();
    await row.click();
    page.once('dialog', (d) => d.accept());
    await page.locator('.pr-detail').getByRole('button', { name: /Approve & apply/ }).click();
    await expect(page.locator('.pr-detail .pr-badge').first()).toHaveText(/applied/i, { timeout: 120_000 });
    expect((await sh(hosts['e2e-deb-1'], `cat ${file}`)).stdout).toContain('alpha = 2');

    const second = await mcp({ alpha: '3' });
    expect(second.proposed).toBe(true);
    await page.locator('.pr-segbtn', { hasText: /^Pending$/ }).click();
    const row2 = page.locator('.pr-row').filter({ hasText: `Set ${file} on e2e-deb-1` }).first();
    await row2.click();
    await page.locator('.pr-detail').getByRole('button', { name: /Reject/ }).click();
    await expect(page.locator('.pr-detail .pr-badge').first()).toHaveText(/rejected/i);
    expect((await sh(hosts['e2e-deb-1'], `cat ${file}`)).stdout).toContain('alpha = 2');
  } finally {
    await sh(hosts['e2e-deb-1'], `rm -f ${file}`);
    if (token.id) await api.delete(`/api/v1/api-tokens/${token.id}`);
    if (before) await setYolo(api, true);
  }
}));

/** One MCP tool call over the streamable-HTTP facade (initialize → initialized → tools/call). */
async function mcpCall(raw: string, tool: string, args: Record<string, unknown>): Promise<any> {
  const { request } = await import('@playwright/test');
  const { API_URL } = await import('./support/env');
  const ctx = await request.newContext({ baseURL: API_URL, extraHTTPHeaders: {
    Authorization: `Bearer ${raw}`, Accept: 'application/json, text/event-stream', 'Content-Type': 'application/json' } });
  const parse = async (r: import('@playwright/test').APIResponse) => {
    const text = await r.text();
    const data = text.split('\n').filter((l) => l.startsWith('data:')).map((l) => l.slice(5).trim()).pop() ?? text;
    return JSON.parse(data);
  };
  const init = await ctx.post('/mcp/', { data: { jsonrpc: '2.0', id: 1, method: 'initialize',
    params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'e2e', version: '1' } } } });
  expect(init.ok(), `MCP initialize: ${init.status()}`).toBeTruthy();
  const session = init.headers()['mcp-session-id'];
  const headers: Record<string, string> = session ? { 'mcp-session-id': session } : {};
  await ctx.post('/mcp/', { headers, data: { jsonrpc: '2.0', method: 'notifications/initialized' } });
  const res = await parse(await ctx.post('/mcp/', { headers, data: { jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: tool, arguments: args } } }));
  await ctx.dispose();
  const content = res.result?.structuredContent ?? JSON.parse(res.result?.content?.[0]?.text ?? '{}');
  return content.result ?? content;
}
