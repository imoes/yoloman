import { test, expect, Page, APIRequestContext } from '@playwright/test';
import { resolve } from 'node:path';
import {
  RUN, agentId, apiAs, callTool, ok, pageAs, setMonaco, setYolo, until, why, withLock, yolo,
} from './support/deploy-scenario';

/**
 * Role management end to end: authoring a `role:` document, its versioned artifact, importing an Ansible role
 * tree, binding a role to a host through the approval gate, the host write gate, and the version history.
 *
 *   A1 author → lint → save = artifact v1; edit → v2; unchanged save → still v2
 *   A2 lint error names its line; a name taken by a non-role plan is refused with the reason
 *   A3 directory import: preview writes nothing, import, re-import changes nothing
 *   A4 bind (pending with YOLO off) → four-eyes approval in Change proposals → unbind; YOLO on → active at once
 *   A5 write gate: Enable writes / Set read-only
 *   A6 version history with a diff
 */

test.describe.configure({ mode: 'serial' });
test.setTimeout(300_000);

const ROLE = `e2e_role_${RUN}`;
const FOLDER = `e2e/${RUN}`;
const roleDoc = (pkgMarker: string) => `role: ${ROLE}
description: e2e authored role
tasks:
  - name: write a marker
    copy:
      dest: /tmp/${ROLE}.txt
      content: "${pkgMarker}"
`;

let api: APIRequestContext;
let deb1 = '';
let debRo = '';

async function runbookId(name: string): Promise<string | undefined> {
  const { runbooks } = await ok<any>(api.get('/api/v1/runbooks'), 'runbooks');
  return runbooks.find((r: any) => r.name === name)?.id;
}
async function artifact(name: string): Promise<any> {
  const { artifacts } = await ok<any>(api.get('/api/v1/role-artifacts'), 'artifacts');
  return artifacts.find((a: any) => a.name === name);
}

/** Open a runbook from the editor's library tree: expand its folder path, then click it. */
async function openFromTree(page: Page, folder: string, name: string) {
  for (const seg of folder.split('/')) {
    // A folder row is `<li><mat-icon>folder|folder_open</mat-icon>name</li>`: match the name text node exactly.
    const folders = page.locator('.bm-tree li.bm-fold');
    await expect(folders.first()).toBeVisible();
    const find = () => folders.evaluateAll((els, name) => els.findIndex((e) => (e.lastChild?.textContent || '').trim() === name), seg);
    await expect.poll(find, { message: `folder ${seg} in the library tree` }).toBeGreaterThanOrEqual(0);
    const idx = await find();
    const node = folders.nth(idx);
    if (!(await node.innerText()).includes('folder_open')) await node.click();
  }
  await page.locator('.bm-tree li.bm-rb', { hasText: name }).click();
}

async function openEditor(page: Page) {
  await page.goto('/runbooks');
  await expect(page.locator('.bm-editor .monaco-editor')).toBeVisible();
  await page.getByRole('button', { name: 'New runbook' }).click();
}

async function openRoleBindings(page: Page, agent: string) {
  await page.goto(`/hosts/${agent}?tab=management`);
  await page.locator('.bm-mmc-node', { hasText: 'Role bindings' }).click();
  await expect(page.locator('app-role-bindings h3')).toHaveText('Role bindings');
}

test.beforeAll(async () => {
  api = await apiAs('admin');
  deb1 = await agentId(api, 'e2e-deb-1');
  debRo = await agentId(api, 'e2e-deb-ro');
  // A directory import from an earlier, aborted run would otherwise make A3's "created" a "refused".
  const stale = await runbookId('motd-role-tasks-main');
  if (stale) await api.delete(`/api/v1/runbooks/${stale}`);
});

test.afterAll(async () => {
  const id = await runbookId(ROLE);
  if (id) await api.delete(`/api/v1/runbooks/${id}`);
  const plan = await artifact(ROLE);
  if (plan) await api.delete(`/api/v1/orchestration/plans/${plan.id}`);
  await callTool(api, deb1, 'command', { argv: ['sh', '-c', `rm -f /tmp/${ROLE}.txt`] }).catch(() => undefined);
  await api.dispose();
});

test('A1 a role written in the editor becomes a versioned artifact; an unchanged save publishes nothing', async ({ page }) => {
  await openEditor(page);
  await setMonaco(page, '.bm-editor', roleDoc('v1'));
  await page.getByRole('button', { name: 'Lint' }).click();
  await expect(page.locator('.bm-lint')).toHaveText(`✓ role “${ROLE}” — 1 step(s), valid.`);
  await page.getByLabel('Folder').fill(FOLDER);
  await page.getByRole('button', { name: 'Save as new' }).click();
  await expect(page.locator('.bm-toolbar .bm-dim').first()).toHaveText(
    `saved: ${ROLE} · role artifact v1 (Deploy → Roles & Features)`);

  await page.goto('/role-deployments');
  const a1 = await artifact(ROLE);
  expect(a1.current_version).toBe(1);
  await expect(page.getByLabel('Role or feature').locator(`option[value="${a1.id}"]`)).toHaveText(`${a1.display_name} · role · v1`);

  // Edit + save → v2; the same text again → still v2 (no empty version).
  await page.goto('/runbooks');
  await openFromTree(page, FOLDER, ROLE);
  await expect(page.locator('.bm-lint')).toContainText('valid');
  await setMonaco(page, '.bm-editor', roleDoc('v2'));
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.locator('.bm-toolbar .bm-dim').first()).toContainText('role artifact v2');
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.locator('.bm-toolbar .bm-dim').first()).toContainText('role artifact v2');
  expect((await artifact(ROLE)).current_version).toBe(2);
  await page.goto('/role-deployments');
  await expect(page.getByLabel('Role or feature').locator(`option[value="${a1.id}"]`)).toHaveText(`${a1.display_name} · role · v2`);
});

test('A2 a lint error names its line; a name held by a non-role plan is refused with the reason', async ({ page }) => {
  await openEditor(page);
  await setMonaco(page, '.bm-editor', `role: broken_${RUN}\ntasks:\n  - name: a\n    package: {name: tree, state: present\n`);
  await page.getByRole('button', { name: 'Lint' }).click();
  await expect(page.locator('.bm-lint')).toContainText('✗ invalid YAML');
  await expect(page.locator('.bm-lint')).toContainText('(line 4)');

  const clash = `e2e_cluster_${RUN}`;
  const plan = await ok<any>(api.post('/api/v1/orchestration/plans', { data: {
    name: clash, display_name: 'e2e clash', plan_type: 'cluster' } }), 'non-role plan');
  try {
    await setMonaco(page, '.bm-editor', `role: ${clash}\ntasks:\n  - name: a\n    debug:\n      msg: hi\n`);
    await page.getByRole('button', { name: 'Save as new' }).click();
    await expect(page.locator('.bm-toolbar .bm-dim').first()).toHaveText(
      `save failed: an orchestration plan named '${clash}' already exists and is cluster`);
    expect(await runbookId(clash), 'a refused save stores nothing').toBeUndefined();
  } finally {
    await api.delete(`/api/v1/orchestration/plans/${plan.id}`);
  }
});

test('A3 importing an Ansible role directory: preview writes nothing, import stores it, re-import changes nothing', async ({ page }) => {
  await page.goto('/plan-library');
  await page.getByRole('button', { name: /Import a plan/ }).click();
  await page.locator('label.bm-inline input').fill(FOLDER);
  await page.locator('input[type=file][webkitdirectory]').setInputFiles(resolve('e2e/fixtures/motd-role'));
  await expect(page.getByText(/3 file\(s\) selected from/)).toBeVisible();

  const status = page.locator('.bm-import [role=status]');
  await page.getByRole('button', { name: 'Preview' }).click();
  await expect(status).toHaveText('Preview — nothing was written: 1 plan(s) (1 would be created) · 2 not a plan · 0 refused');
  await expect(page.locator('.bm-bulk-list')).toContainText('motd-role/tasks/main.yml → Sequence motd-role-tasks-main');
  expect(await runbookId('motd-role-tasks-main'), 'the preview wrote nothing').toBeUndefined();

  await page.getByRole('button', { name: /Import 3 file/ }).click();
  await expect(status).toHaveText('Imported: 1 plan(s) (1 created) · 2 not a plan · 0 refused');
  const id = await runbookId('motd-role-tasks-main');
  expect(id).toBeTruthy();
  try {
    await page.getByRole('button', { name: /Import 3 file/ }).click();
    await expect(status).toHaveText('Imported: 1 plan(s) (1 unchanged) · 2 not a plan · 0 refused');
    const { runbooks } = await ok<any>(api.get('/api/v1/runbooks'), 'runbooks');
    expect(runbooks.filter((r: any) => r.name === 'motd-role-tasks-main')).toHaveLength(1);
    // It landed where the result says: a Sequence in the chosen folder.
    const link = page.locator('.bm-bulk-list a', { hasText: 'open in Sequences' });
    await link.evaluate((a) => a.scrollIntoView({ block: 'center' }));
    await link.click();
    await expect(page).toHaveURL(/\/runbooks/);
    await openFromTree(page, FOLDER, 'motd-role-tasks-main');
    await expect(page.locator('.bm-lint')).toContainText('valid');
  } finally {
    await api.delete(`/api/v1/runbooks/${id}`);
  }
});

test('A4 binding a role needs a second administrator with YOLO off, and is active at once with YOLO on', async ({ page, browser }) => withLock('yolo', async () => {
  const yoloBefore = await yolo(api);
  if (yoloBefore) await setYolo(api, false);
  try {
    await openRoleBindings(page, deb1);
    await page.getByLabel('Filter roles').fill(ROLE);
    const node = page.locator('app-resource-node').filter({ hasText: ROLE });
    await expect(node).toHaveCount(1);
    await expect(node).toContainText('not bound to this host');
    await node.getByRole('button', { name: 'Plan' }).click();
    await expect(node.locator('.bm-rn-plan')).toContainText('plan: create');
    await node.getByRole('button', { name: 'Bind' }).click();
    await expect(node).toContainText('Bound — pending approval');
    await expect(node).toContainText('pending approval — decided under Change proposals');

    // The requester sees the binding in the approval queue, but cannot approve it — and is told why.
    await page.goto('/change-proposals');
    const mine = page.locator('.pr-link').filter({ hasText: `${ROLE} → host e2e-deb-1` });
    await expect(mine).toHaveCount(1);
    await expect(mine).toContainText('ui-e2e-admin');
    const approveMine = mine.getByRole('button', { name: 'Approve' });
    await expect(approveMine).toBeDisabled();
    expect(await why(approveMine)).toBe('Four-eyes: another administrator must approve — you requested this binding');

    const other = await pageAs(browser, 'admin2');
    try {
      await other.page.goto('/change-proposals');
      const theirs = other.page.locator('.pr-link').filter({ hasText: `${ROLE} → host e2e-deb-1` });
      await expect(theirs.getByRole('button', { name: 'Approve' })).toBeEnabled();
      await theirs.getByRole('button', { name: 'Approve' }).click();
      await expect(other.page.locator('.pr-links [role=status]')).toHaveText(`Approved: ${ROLE} → host e2e-deb-1 is now active.`);
      await expect(theirs).toHaveCount(0);
    } finally {
      await other.ctx.close();
    }

    await openRoleBindings(page, deb1);
    await page.getByLabel('Filter roles').fill(ROLE);
    await expect(node).toContainText(/bound .*active/);
    await node.getByRole('button', { name: 'Unbind' }).click();
    await expect(node).toContainText('Unbound (1 link).');
    await expect(node).toContainText('not bound to this host');

    // YOLO on (the switch in OU / Policy): a binding is active at once — and the switch goes back off.
    await page.goto('/ou');
    const toggle = page.locator('mat-slide-toggle', { hasText: 'YOLO-MAN' });
    await expect(toggle).toContainText('YOLO-MAN OFF');
    await toggle.locator('button').click();
    await expect(toggle).toContainText('YOLO-MAN ON');
    try {
      await openRoleBindings(page, deb1);
      await page.getByLabel('Filter roles').fill(ROLE);
      await node.getByRole('button', { name: 'Bind' }).click();
      await expect(node).toContainText('Bound (active)');
    } finally {
      await page.goto('/ou');
      await toggle.locator('button').click();
      await expect(toggle).toContainText('YOLO-MAN OFF');
    }
    await openRoleBindings(page, deb1);
    await page.getByLabel('Filter roles').fill(ROLE);
    await node.getByRole('button', { name: 'Unbind' }).click();
    await expect(node).toContainText('Unbound (1 link).');
  } finally {
    await setYolo(api, yoloBefore);
  }
}));

test('A5 the write gate: Enable writes, then Set read-only, on the read-only test host', async ({ page }) => withLock('deb-ro-gate', async () => {
  const write = async () => api.post(`/api/v1/agents/${debRo}/tools/file`, {
    data: { params: { path: `/tmp/e2e-a5-${RUN}`, state: 'touch' } } });
  await openRoleBindings(page, debRo);
  const gate = page.locator('.bm-rb-write');
  await gate.getByRole('button', { name: 'Enable writes' }).click();
  await expect(page.locator('app-role-bindings .bm-ok')).toHaveText(
    'Writes enabled — the agent is restarting; approved roles will converge on the next reconcile.', { timeout: 60_000 });
  await until(async () => (await write()).ok(), 'e2e-deb-ro accepts a write once the gate is open', 120_000);

  await gate.getByRole('button', { name: 'Set read-only' }).click();
  await expect(page.locator('app-role-bindings .bm-ok')).toHaveText('Host set back to read-only — the agent is restarting.', { timeout: 60_000 });
  await until(async () => {
    const r = await write();
    return !r.ok() && /read-only|write/i.test(await r.text());
  }, 'e2e-deb-ro refuses writes again', 120_000);
}));

test('A6 the role artifact keeps its version history, and two versions can be compared', async ({ page }) => {
  const a = await artifact(ROLE);
  await page.goto('/role-deployments');
  await page.getByLabel('Role or feature').selectOption(a.id);
  const history = page.locator('details.rd-versions');
  await history.locator('summary').click();
  await expect(history.locator('summary')).toHaveText(`Version history · ${a.display_name} (current v2)`);
  await expect(history.locator('.rd-version-list li')).toHaveCount(2);
  await expect(history.locator('.rd-version-list li').last()).toContainText('current');
  await expect(history.getByLabel('Older version')).toHaveValue(/1/);
  const diff = history.locator('app-version-diff');
  await expect(diff.locator('.bm-vd-labels')).toHaveText(/v1\s*v2/);
  await expect(diff.locator('.monaco-diff-editor')).toBeVisible();
  // The changed line is shown on both sides: v1's marker on the left, v2's on the right.
  await expect(diff.locator('.editor.original')).toContainText('"content": "v1"');
  await expect(diff.locator('.editor.modified')).toContainText('"content": "v2"');
});
