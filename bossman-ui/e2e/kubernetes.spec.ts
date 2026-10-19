import { test, expect, Page, Browser, APIRequestContext } from '@playwright/test';
import { api } from './support/routes';
import { authFile } from './support/env';
import { approveProposal, disabledWithoutReasonIn, eventually, reasonOf, runTag } from './support/scenario';

/**
 * The Kubernetes console lifecycle (docs/kubernetes-console.md, "Verification — the deployment lifecycle"), driven
 * through the UI against the registered cluster "minikube bossman-dev":
 *
 *   registry → explorer → Applications → Create application (fresh namespace) → server dry run → Create
 *   → (YOLO off: change proposal → approve) → Deployment + Pod healthy, inspector State/Pods/Events/Logs
 *   → scale to 2 → broken image → Degraded with the ImagePull reason explained → image back → delete all.
 *
 * One serial flow sharing one page; every step is its own test so a failure names the step. Writes outside
 * YOLO mode file a change proposal, which the flow approves through /change-proposals like an operator. The
 * namespace (and with it everything) is removed at the end — by the UI in the last step, by the API in
 * afterAll if a step failed earlier.
 */

const TAG = runTag();
const NS = `e2e-k8s-${TAG}`;
const APP = `web-${TAG}`;
const IMAGE = 'nginx:1.27';
const BROKEN = 'nginx:doesnotexist-e2e';

let page: Page;
let ctx: APIRequestContext;
let cluster: { id: string; name: string; agent_id: string };
const disabledNoReason: string[] = [];

test.describe.configure({ mode: 'serial' });

async function openContext(browser: Browser) {
  const c = await browser.newContext({ storageState: authFile('admin'), viewport: { width: 1680, height: 1000 } });
  return c.newPage();
}

/** Note every visible disabled control in the main area that does not name its reason (asserted at the end). */
async function auditDisabled(where: string) {
  for (const label of await disabledWithoutReasonIn(page.locator('main'))) disabledNoReason.push(`${where}: ${label}`);
}

/** The result of an apply/scale: applied directly (YOLO on) or a proposal to approve. */
async function approveIfFiled(filedText: string, title: RegExp) {
  if (/Filed for approval/i.test(filedText)) {
    await approveProposal(page, title);
    return true;
  }
  return false;
}

/** After a Delete click: when YOLO mode is off the deletion is filed as a proposal — approve it, come back. */
async function deleteFiled(title: RegExp, list: [string, string]): Promise<boolean> {
  const note = inspector().locator('.bm-note').first();
  const snack = page.locator('simple-snack-bar, .mat-mdc-snack-bar-label').first();
  await expect(note.or(snack)).toBeVisible({ timeout: 60_000 });
  if (!(await note.isVisible()) || !/Filed for approval/.test(await note.innerText())) return false;
  await approveProposal(page, title);
  await explorer();
  await listKind(list[0], list[1], NS);
  return true;
}

async function explorer() {
  await page.goto(`/kubernetes/${cluster.id}`);
  await expect(page.locator('.bm-scope-title')).toHaveText(cluster.name);
}

/** Select a node in the explorer's source list (opening its group if collapsed). */
async function node(group: string, title: string) {
  const btn = page.locator('button.bm-node').filter({ hasText: new RegExp(`^\\s*\\S+\\s*${title}(\\s+\\d+)?\\s*$`) });
  if (!(await btn.isVisible())) await page.locator('.bm-group-head', { hasText: group }).click();
  await btn.click();
}

/** The list row of our object (filtered by the run tag so other namespaces' "web" rows never match). */
function row(name: string) {
  return page.locator('section.bm-result tr.bm-click').filter({ has: page.getByRole('cell', { name, exact: true }) });
}

async function listKind(group: string, title: string, filter: string) {
  await node(group, title);
  await page.locator('input.bm-filter').fill(filter);
}

async function refreshList() {
  await page.locator('section.bm-result').getByRole('button', { name: 'Refresh' }).click();
  await expect(page.locator('section.bm-result').getByRole('button', { name: 'Refresh' })).toBeEnabled({ timeout: 60_000 });
}

const inspector = () => page.locator('aside.bm-inspector');

async function openRow(name: string) {
  // The drawer covers the right part of the list; the name cell on the left stays clickable. (Closing the
  // drawer first is not possible — see the Close-button test.)
  await row(name).getByRole('cell').first().click();
  await expect(inspector().locator('.bm-ins-head h3')).toHaveText(name, { timeout: 30_000 });
}

/** Re-open the Application form for our app, after refreshing the explorer's cached inventory. */
async function editForm() {
  // Workaround for the stale-inventory bug pinned below: the form's namespace pre-flight reads the cached
  // inventory, so the namespace this run created is unknown to it until the inventory is re-read.
  await explorer();
  await node('Cluster', 'Overview');
  await page.getByRole('button', { name: 'Refresh now' }).click();
  await expect(page.locator('#k8s-ns option', { hasText: NS })).toHaveCount(1, { timeout: 60_000 });
  await page.goto(`/kubernetes/${cluster.id}/apps/${NS}/${APP}`);
  await expect(page.getByRole('heading', { name: 'Edit application', level: 1 })).toBeVisible();
  await expect(page.getByRole('textbox', { name: /^Image/ })).not.toHaveValue('', { timeout: 30_000 });
}

/** Change the image in the form, preview, apply (approving the proposal), and return. */
async function setImage(image: string) {
  await editForm();
  await page.getByRole('textbox', { name: /^Image/ }).fill(image);
  const previewBtn = page.getByRole('button', { name: 'Preview (server dry run)' });
  await expect(previewBtn).toBeEnabled();
  await previewBtn.click();
  // The server-side diff names the image change.
  await expect(page.locator('aside.bm-side')).toContainText('What changes', { timeout: 90_000 });
  await expect(page.locator('aside.bm-side pre.bm-diff').filter({ hasText: image }).first()).toBeVisible();
  await auditDisabled('application form (edit)');
  const apply = page.getByRole('button', { name: 'Apply changes' });
  await expect(apply).toBeEnabled();
  await apply.click();
  const result = page.locator('.bm-result');
  await expect(result).toContainText(/Filed for approval|Applied/, { timeout: 120_000 });
  await approveIfFiled(await result.innerText(), new RegExp(`Application ${APP} on`));
}

test.beforeAll(async ({ browser }) => {
  ctx = await api();
  const clusters = await (await ctx.get('/api/v1/kubernetes/clusters')).json();
  const list: any[] = Array.isArray(clusters) ? clusters : clusters.clusters ?? [];
  cluster = list.find((c) => c.name === 'minikube bossman-dev' && c.reachability === 'reachable') ?? list.find((c) => c.reachability === 'reachable');
  page = await openContext(browser);
});

test.afterAll(async () => {
  // Safety net: if a step failed before the UI delete, remove the namespace (and everything in it) by API.
  if (cluster) {
    const q = new URLSearchParams({ cluster: cluster.id, api_version: 'v1', object_kind: 'Namespace', preview: 'false', require_approval: 'false' });
    await ctx.delete(`/api/v1/agents/${cluster.agent_id}/resources/k8s/${NS}/object?${q}`).catch(() => undefined);
  }
  await page?.context().close();
});

test('the registry shows the cluster as reachable and opens its explorer', async () => {
  test.skip(!cluster, 'no reachable Kubernetes cluster registered');
  test.setTimeout(90_000);
  await page.goto('/kubernetes');
  await expect(page.getByRole('heading', { name: 'Kubernetes clusters', level: 1 })).toBeVisible();
  await page.locator('.bm-item', { hasText: cluster.name }).click();
  await expect(page.getByRole('heading', { name: cluster.name, level: 2 })).toBeVisible();
  await expect(page.getByText('Reachable', { exact: true })).toBeVisible();
  await page.getByRole('link', { name: 'Open explorer' }).click();
  await expect(page).toHaveURL(new RegExp(`/kubernetes/${cluster.id}$`));
  await expect(page.getByRole('heading', { name: 'Overview', level: 2 })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Nodes', level: 3 })).toBeVisible({ timeout: 60_000 });
  await auditDisabled('explorer overview');
});

test('the Application form derives a Deployment and refuses with reasons until it is complete', async () => {
  test.setTimeout(120_000);
  await node('Applications', 'Applications');
  await page.getByRole('link', { name: 'Create application' }).click();
  await expect(page).toHaveURL(new RegExp(`/kubernetes/${cluster.id}/apps/new`));
  await expect(page.getByRole('heading', { name: 'Create application', level: 1 })).toBeVisible();

  // Empty form: both buttons greyed out, and each says why.
  const previewBtn = page.getByRole('button', { name: 'Preview (server dry run)' });
  const createBtn = page.getByRole('button', { name: 'Create', exact: true });
  await expect(createBtn).toBeDisabled();
  expect(await reasonOf(createBtn)).toBe('A name is required.');
  expect(await reasonOf(previewBtn)).toBe('A name is required.');
  await page.getByRole('textbox', { name: 'Name' }).fill(APP);
  await expect.poll(() => reasonOf(createBtn)).toBe('An image is required.');
  await auditDisabled('application form (empty)');

  await page.getByRole('combobox', { name: 'Namespace' }).fill(NS);
  await page.getByRole('textbox', { name: /^Image/ }).fill(IMAGE);
  await page.getByRole('spinbutton', { name: 'Port', exact: true }).fill('80');
  // Stock nginx runs as root: the Restricted profile would crash it (docs: "Baseline per the PSS").
  await page.getByRole('combobox', { name: 'Pod Security profile' }).selectOption('baseline');

  // The namespace does not exist yet: a pre-flight check says so, and Create names it as the reason.
  await expect(page.locator('ul.bm-issues')).toContainText(`namespace '${NS}' does not exist`, { timeout: 20_000 });
  await expect.poll(() => reasonOf(createBtn)).toMatch(/check\(s\) must be fixed first/);
  await auditDisabled('application form (namespace missing)');

  await page.getByRole('checkbox', { name: new RegExp(`create the namespace`) }).check();
  await expect(page.getByText('All pre-flight checks pass.')).toBeVisible({ timeout: 20_000 });
  // The operator never picks a kind: the form derives it and says why.
  await expect(page.locator('.bm-kindbox strong')).toHaveText('Deployment');
  await expect(page.locator('.bm-kindbox')).toContainText('→ Deployment');
  const objects = page.locator('ul.bm-objects li');
  await expect(objects).toHaveText([new RegExp(`Namespace\\s+${NS}`), new RegExp(`Service\\s+${APP}`), new RegExp(`Deployment\\s+${APP}`)]);
});

test('the server dry run answers per object before anything is applied', async () => {
  test.setTimeout(120_000);
  await page.getByRole('button', { name: 'Preview (server dry run)' }).click();
  const objects = page.locator('ul.bm-objects li');
  await expect(objects.locator('.bm-pill')).toHaveText(['create', 'create', 'create'], { timeout: 90_000 });
  await expect(page.locator('.bm-refused')).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Create', exact: true })).toBeEnabled();
});

test('the preview says the namespaced objects could not be validated yet (deferred)', async () => {
  // Regression (fixed): the API reports the Service and Deployment as "server validation deferred: namespace …
  // is created first in this set"; the UI showed them as a plain green "create" — a verdict the server did not give.
  await expect(page.locator('ul.bm-objects .bm-pill')).toHaveCount(3);
  await expect(page.locator('aside.bm-side')).toContainText(/deferred/i, { timeout: 5_000 });
});

test('Create applies the application (through a change proposal when YOLO mode is off)', async () => {
  test.setTimeout(300_000);
  await page.getByRole('button', { name: 'Create', exact: true }).click();
  const result = page.locator('.bm-result');
  await expect(result).toContainText(/Filed for approval|Applied/, { timeout: 120_000 });
  const filed = await result.innerText();
  if (/Filed for approval/.test(filed)) {
    await expect(result.getByRole('link', { name: 'Open proposals' })).toBeVisible();
    const detail = await approveProposal(page, new RegExp(`Application ${APP} on .*\\(3 objects\\)`));
    expect(detail).toContain('"applied": true');
  }
});

test('the explorer namespace picker lists the namespace the application just created', async () => {
  // Regression (fixed): the namespace list comes from the cached inventory (15 min); an apply through Bossman
  // did not refresh it, so right after creating namespace X the picker lacked X.
  test.setTimeout(60_000);
  await explorer();
  await expect(page.locator('#k8s-ns option').first()).toBeAttached();
  await expect(page.locator('#k8s-ns option', { hasText: NS })).toHaveCount(1, { timeout: 10_000 });
});

test('the Deployment and its Pod become healthy; the inspector shows state, pods, events and logs', async () => {
  test.setTimeout(300_000);
  await explorer();
  await listKind('Workloads', 'Deployments', NS);
  await eventually(async () => {
    await refreshList();
    return /Healthy/.test(await row(APP).innerText()) && /1\/1/.test(await row(APP).innerText());
  }, `Deployment ${APP} healthy 1/1`);
  await expect(row(APP)).toContainText(IMAGE);

  await openRow(APP);
  const ins = inspector();
  await expect(ins.locator('.bm-ins-head')).toContainText(`Deployment · ${NS}`);
  await expect(ins.locator('.bm-ins-head .bm-pill')).toHaveText('Healthy');
  // State: the etcd key as explanation, the field manager, generation desired/observed.
  await expect(ins.getByRole('tabpanel')).toContainText(`/registry/deployments/${NS}/${APP}`, { timeout: 30_000 });
  await expect(ins.getByRole('tabpanel')).toContainText('bossman');
  // Every greyed-out action names its reason (e.g. "Resume rollout" — not paused).
  for (const b of await ins.locator('.bm-actionbar button:disabled').all()) {
    expect(await reasonOf(b), `disabled action "${(await b.innerText()).trim()}" names its reason`).not.toBe('');
  }

  await ins.getByRole('tab', { name: 'Pods' }).click();
  await expect(ins.getByRole('tabpanel')).toContainText(`app.kubernetes.io/instance=${APP}`);
  const podRow = ins.getByRole('tabpanel').locator('tr.bm-click').first();
  await expect(podRow).toContainText('Healthy', { timeout: 60_000 });
  await expect(podRow).toContainText('1/1');

  await ins.getByRole('tab', { name: 'Events' }).click();
  await expect(ins.getByRole('tabpanel')).toContainText('ScalingReplicaSet', { timeout: 30_000 });

  // The pod: Running, with logs.
  await ins.getByRole('tab', { name: 'Pods' }).click();
  await ins.getByRole('tabpanel').locator('tr.bm-click').first().click();
  await expect(ins.locator('.bm-ins-head')).toContainText(`Pod · ${NS}`, { timeout: 30_000 });
  await expect(ins.locator('.bm-ins-head .bm-pill')).toHaveText('Healthy');
  await ins.getByRole('tab', { name: 'Logs' }).click();
  await expect(ins.locator('pre.bm-log')).toContainText(/docker-entrypoint|nginx/, { timeout: 60_000 });
  await auditDisabled('explorer inspector');
});

test('the inspector drawer can be closed with its Close button', async () => {
  // Regression (fixed): the shell's floating "Event Console" button sat on top of the inspector's Close (×),
  // and the list's sticky table header painted over the drawer.
  await expect(inspector().locator('.bm-ins-head')).toBeVisible();
  await inspector().getByRole('button', { name: 'Close' }).click({ timeout: 5_000 });
  await expect(inspector().locator('.bm-ins-head')).toHaveCount(0);
});

test('the YAML tab: Preview runs the server dry run; the greyed-out Apply says why', async () => {
  // Regressions (fixed): the YAML tab's Apply was [disabled] without its reason; and openRow() did not cancel the
  // previous object's requests, so the draft could show the PREVIOUSLY opened Pod's manifest under the Deployment.
  test.setTimeout(180_000);
  const ins = inspector();
  await openRow(APP);
  await ins.getByRole('tab', { name: 'YAML' }).click();
  await expect(ins.locator('textarea.bm-yaml-edit')).toHaveValue(/"kind": "Deployment"/, { timeout: 30_000 });
  await ins.getByRole('tabpanel').getByRole('button', { name: 'Preview' }).click();
  await expect(ins.getByRole('tabpanel')).toContainText(/Server verdict: (noop|update)/, { timeout: 60_000 });
  const apply = ins.getByRole('tabpanel').getByRole('button', { name: 'Apply' });
  await expect(apply).toBeDisabled();   // unchanged manifest → noop → nothing to apply
  expect(await reasonOf(apply)).not.toBe('');
});

test('scaling to 2 is gated, approved, and reaches 2/2', async () => {
  test.setTimeout(300_000);
  await openRow(APP);
  const ins = inspector();
  await ins.getByRole('button', { name: 'Scale…' }).click();
  await ins.getByRole('spinbutton', { name: 'Replicas' }).fill('2');
  await ins.getByRole('button', { name: 'Scale', exact: true }).click();
  const note = ins.locator('.bm-note').first();
  await expect(note).toContainText(/Filed for approval|Scale…: done/, { timeout: 120_000 });
  const filed = await approveIfFiled(await note.innerText(), new RegExp(`Deployment ${NS}/${APP} .* scale to 2`));
  if (filed) {
    await explorer();
    await listKind('Workloads', 'Deployments', NS);
  }
  await eventually(async () => {
    await refreshList();
    return /2\/2/.test(await row(APP).innerText()) && /Healthy/.test(await row(APP).innerText());
  }, `Deployment ${APP} healthy 2/2`);
});

test('a broken image turns the Deployment Degraded, with the ImagePull reason explained', async () => {
  test.setTimeout(420_000);
  await setImage(BROKEN);
  await explorer();
  await listKind('Workloads', 'Deployments', NS);
  await eventually(async () => {
    await refreshList();
    const t = await row(APP).innerText();
    return /Degraded|Failed/.test(t) && t.includes(BROKEN);
  }, `Deployment ${APP} degraded on ${BROKEN}`, 240_000);
  // The row's pill carries the pod's reason as its title.
  expect(await row(APP).locator('.bm-pill').getAttribute('title')).toMatch(/ImagePull|ErrImagePull/);

  await openRow(APP);
  const why = inspector().locator('.bm-why-box');
  await expect(why).toBeVisible();
  await expect(why).toContainText(/ImagePullBackOff|ErrImagePull/);
  await expect(why).toContainText('What to do:');
  await expect(why.getByRole('link', { name: /kubernetes\.io/ })).toBeVisible();
  await inspector().getByRole('tab', { name: 'Events' }).click();
  await auditDisabled('inspector (degraded)');
});

test('setting the image back heals the Deployment to 2/2', async () => {
  test.setTimeout(420_000);
  await setImage(IMAGE);
  await explorer();
  await listKind('Workloads', 'Deployments', NS);
  await eventually(async () => {
    await refreshList();
    const t = await row(APP).innerText();
    return /Healthy/.test(t) && /2\/2/.test(t) && t.includes(IMAGE) && !t.includes(BROKEN);
  }, `Deployment ${APP} healthy again on ${IMAGE}`, 240_000);
});

test('delete previews what goes with each object, then the app and its namespace are gone', async () => {
  test.setTimeout(420_000);
  // The Deployment: its ReplicaSet and Pods go with it.
  await openRow(APP);
  await inspector().getByRole('button', { name: 'Delete…' }).click();
  const confirm = inspector().locator('.bm-inline--col');
  await expect(confirm).toContainText(`Delete Deployment ${APP}?`, { timeout: 60_000 });
  await expect(confirm).toContainText('Goes with it:');
  await expect(confirm).toContainText('ReplicaSet/');
  await confirm.getByRole('button', { name: 'Delete', exact: true }).click();
  // A deletion passes the same approval gate as an apply or a scale: filed as a proposal unless YOLO mode is on.
  if (!(await deleteFiled(new RegExp(`Delete Deployment ${NS}/${APP} on`), ['Workloads', 'Deployments']))) {
    await expect(page.locator('simple-snack-bar, .mat-mdc-snack-bar-label').first()).toContainText(/generation \d+/, { timeout: 60_000 });
  }
  await eventually(async () => {
    await refreshList();
    return (await row(APP).count()) === 0;
  }, `Deployment ${APP} gone`, 120_000);

  // The Service.
  await listKind('Network', 'Services', NS);
  await eventually(async () => {
    await refreshList();
    return (await row(APP).count()) === 1;
  }, `Service ${APP} listed`, 60_000);
  await openRow(APP);
  await inspector().getByRole('button', { name: 'Delete…' }).click();
  await expect(inspector().locator('.bm-inline--col')).toContainText(`Delete Service ${APP}?`, { timeout: 60_000 });
  await inspector().locator('.bm-inline--col').getByRole('button', { name: 'Delete', exact: true }).click();
  await deleteFiled(new RegExp(`Delete Service ${NS}/${APP} on`), ['Network', 'Services']);
  await eventually(async () => {
    await refreshList();
    return (await row(APP).count()) === 0;
  }, `Service ${APP} gone`, 120_000);

  // The namespace.
  await listKind('Cluster', 'Namespaces', NS);
  await eventually(async () => {
    await refreshList();
    return (await row(NS).count()) === 1;
  }, `Namespace ${NS} listed`, 60_000);
  await openRow(NS);
  await inspector().getByRole('button', { name: 'Delete…' }).click();
  await expect(inspector().locator('.bm-inline--col')).toContainText(`Delete Namespace ${NS}?`, { timeout: 60_000 });
  // A namespace takes everything in it along — the preview says what is still there.
  await expect(inspector().locator('.bm-inline--col')).toContainText(/Goes with it:|Nothing else depends on it/);
  await inspector().locator('.bm-inline--col').getByRole('button', { name: 'Delete', exact: true }).click();
  await deleteFiled(new RegExp(`Delete Namespace ${NS} on`), ['Cluster', 'Namespaces']);
  await eventually(async () => {
    await refreshList();
    const n = await row(NS).count();
    return n === 0 || /Terminating/.test(await row(NS).innerText());
  }, `Namespace ${NS} terminating or gone`, 180_000);
});

test('every disabled control met on the way named its reason', async () => {
  // Collected by auditDisabled() at each step: a disabled control without a title/bm-why is a refusal
  // without its reason (CLAUDE.md rule 4).
  expect(disabledNoReason).toEqual([]);
});

test('editing an application right after creating its namespace is not blocked by a stale check', async ({ browser }) => {
  // Regression (fixed): validate() checked the namespace against the CACHED inventory, so right after the app
  // (and its namespace) were created the edit form said "namespace … does not exist" and "Apply changes" stayed
  // disabled. Reproduced with a second, minimal application (cleaned up below).
  test.setTimeout(300_000);
  const tag2 = runTag();
  const ns2 = `e2e-k8s-${tag2}`;
  const app2 = `stale-${tag2}`;
  const p = await openContext(browser);
  try {
    await p.goto(`/kubernetes/${cluster.id}/apps/new`);
    await p.getByRole('textbox', { name: 'Name' }).fill(app2);
    await p.getByRole('combobox', { name: 'Namespace' }).fill(ns2);
    await p.getByRole('textbox', { name: /^Image/ }).fill(IMAGE);
    await p.getByRole('spinbutton', { name: 'Port', exact: true }).fill('80');
    await p.getByRole('combobox', { name: 'Pod Security profile' }).selectOption('baseline');
    await p.getByRole('checkbox', { name: /create the namespace/ }).check();
    await expect(p.getByText('All pre-flight checks pass.')).toBeVisible({ timeout: 20_000 });
    await p.getByRole('button', { name: 'Create', exact: true }).click();
    const result = p.locator('.bm-result');
    await expect(result).toContainText(/Filed for approval|Applied/, { timeout: 120_000 });
    if (/Filed for approval/.test(await result.innerText())) await approveProposal(p, new RegExp(`Application ${app2} on`));
    await p.goto(`/kubernetes/${cluster.id}/apps/${ns2}/${app2}`);
    await expect(p.getByRole('textbox', { name: /^Image/ })).not.toHaveValue('', { timeout: 30_000 });
    // Wait for the form's server render of the edited values (the pre-flight checks come with it).
    const rendered = p.waitForResponse((r) => r.url().includes('/applications/render') && r.request().method() === 'POST');
    await p.getByRole('spinbutton', { name: 'Instances' }).fill('2');
    await rendered;
    await expect(p.locator('ul.bm-objects li').first()).toBeVisible();
    await expect(p.locator('aside.bm-side')).not.toContainText('does not exist');
    await expect(p.getByRole('button', { name: 'Apply changes' })).toBeEnabled();
  } finally {
    const q = new URLSearchParams({ cluster: cluster.id, api_version: 'v1', object_kind: 'Namespace', preview: 'false', require_approval: 'false' });
    await ctx.delete(`/api/v1/agents/${cluster.agent_id}/resources/k8s/${ns2}/object?${q}`).catch(() => undefined);
    await p.context().close();
  }
});
