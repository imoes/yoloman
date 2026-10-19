import { test, expect, Page, APIRequestContext, Locator } from '@playwright/test';
import { api } from './support/routes';
import { authFile } from './support/env';
import { agentByName, disabledWithoutReasonIn, reasonOf } from './support/scenario';

/**
 * Package lifecycle scenarios on the enrolled e2e hosts (systemd containers with real apt / dnf, installs go
 * through the corporate proxy). The packages are the ones configs/package_e2e_results.jsonl reports as
 * installing cleanly on both families: redis, memcached, haproxy (and a role that is NOT on the family).
 *
 *   (a) Management console (/mmc) → "Installed packages" (the Linux title of Programs and Features)
 *       → "Install a package…" (preview, then apply) → the packages appear in the list.
 *   (b) Host → Management → Roles & Features → Add roles wizard: a role not on the family is greyed out
 *       with "Not on <family>" and its reason; HAProxy configured (enum dropdowns), validated (dry run),
 *       installed → /role-deployments lists it, the host's role reads Compliant.
 *   (d) Host → Management → Configuration (Settings): one redis.conf value changed → applied → a new
 *       generation appears → rollback preview.
 *   (c) Host → Resources → Packages: haproxy planned/applied absent, then present again, rollback.
 *   cleanup: role uninstalled through the UI, redis/memcached removed through the console form.
 *
 * One serial flow per host, sharing one page; every step is its own test so a failure names the step. Known
 * product bugs are pinned with test.fail() placed right before the failing assertion, so the setup still has
 * to work for the expectation to count.
 */

interface HostCase {
  name: string;
  family: 'debian' | 'redhat';
  redis: string;               // the distro's redis package
  memcached: string;
  notOnFamily: { label: string; reason: RegExp };
}

const HOSTS: HostCase[] = [
  { name: 'e2e-deb-1', family: 'debian', redis: 'redis-server', memcached: 'memcached',
    notOnFamily: { label: 'IIS Web Server', reason: /./ } },
  { name: 'e2e-rh-1', family: 'redhat', redis: 'redis', memcached: 'memcached',
    notOnFamily: { label: 'AppArmor', reason: /SELinux/ } },
];
const ROLE = { label: 'HAProxy Load Balancer', search: 'haproxy', pkg: 'haproxy', enumIndex: 2, enumValue: 'leastconn' };
const REDIS_CONF = '/etc/redis/redis.conf';

// ── shared navigation helpers ─────────────────────────────────────────────────────────────────────────────

async function newPage(browser: import('@playwright/test').Browser): Promise<Page> {
  const ctx = await browser.newContext({ storageState: authFile('admin'), viewport: { width: 1600, height: 1000 } });
  return ctx.newPage();
}

/** /mmc for one host, with the "Installed packages" node open. */
async function openInstalledPackages(page: Page, host: string) {
  await page.goto('/mmc');
  await expect(page.getByRole('heading', { name: 'Management console', level: 1 })).toBeVisible();
  await page.getByRole('combobox', { name: 'Host' }).selectOption({ label: host });
  await expect(page).toHaveURL(/\/mmc\?host=/);
  const snapin = page.locator('.bm-snapin').filter({ has: page.locator('.bm-sname', { hasText: /^(Installed packages|Programs and Features)$/ }) });
  await expect(snapin).toBeVisible({ timeout: 30_000 });
  if (!(await snapin.locator('button.bm-node').first().isVisible())) await snapin.locator('.bm-snapin-head').click();
  await snapin.locator('button.bm-node').first().click();
  await expect(page.locator('.bm-result-head h2')).toHaveText(/Installed (packages|programs)/, { timeout: 60_000 });
  await expect(page.locator('.bm-result-head')).toContainText(`row(s) · ${host}`, { timeout: 120_000 });
}

/** The console rows whose Name cell is exactly `pkg` (the filter box narrows, the cell match is exact). */
async function packageRow(page: Page, pkg: string): Promise<Locator> {
  await page.locator('input.bm-filter').fill(pkg);
  return page.locator('.bm-table tbody tr').filter({ has: page.getByRole('cell', { name: pkg, exact: true }) });
}

/** The console's "Install a package…" form: names, state, preview first, then the real apply. */
async function packageForm(page: Page, names: string[], state: 'present' | 'absent', preview: boolean) {
  const form = page.locator('.bm-form');
  if (!(await form.isVisible())) await page.getByRole('button', { name: /Install a package/ }).click();
  await expect(form).toBeVisible();
  await form.getByRole('textbox', { name: /^name/ }).fill(names.join(', '));
  await form.getByRole('combobox', { name: /^state/ }).selectOption(state);
  const dry = form.getByRole('checkbox', { name: /Preview only/ });
  if (preview) await dry.check(); else await dry.uncheck();
  await form.getByRole('button', { name: preview ? 'Preview' : 'Apply' }).click();
}

async function openHostTab(page: Page, id: string, tab: 'management' | 'resources') {
  await page.goto(`/hosts/${id}?tab=${tab}`);
  await expect(page.getByRole('tab', { name: tab === 'management' ? 'Management' : 'Resources' })).toHaveAttribute('aria-selected', 'true', { timeout: 30_000 });
}

async function openSnapin(page: Page, label: string) {
  const panel = page.getByRole('tabpanel');
  await panel.getByRole('button', { name: label, exact: true }).click();
  return panel;
}

async function openRolesFeatures(page: Page, id: string) {
  // The dev stack is rebuilt by a parallel agent from time to time; a load that hits the restart window
  // stays on "Loading catalog…" (the component swallows the error — see the report), so retry the page.
  for (let attempt = 1; ; attempt++) {
    await openHostTab(page, id, 'management');
    const panel = await openSnapin(page, 'Roles & Features');
    await expect(panel.getByRole('heading', { name: 'Roles & Features', level: 3 })).toBeVisible();
    const add = panel.getByRole('button', { name: /Add roles and features/ });
    try {
      await expect(add).toBeEnabled({ timeout: 45_000 });
      await expect(panel.getByText('Loading catalog…')).toHaveCount(0, { timeout: 30_000 });
      return panel;
    } catch (e) {
      if (attempt >= 3) throw e;
    }
  }
}

/** Reload the host document and select the category holding `path`; retries the Reload a few times
 * because the document is cached server-side and a just-installed file may need a second read. */
async function findConfigFile(page: Page, panel: Locator, path: string): Promise<Locator> {
  const file = panel.locator(`.bm-gpo-file[title="${path}"]`);
  for (let attempt = 0; attempt < 4; attempt++) {
    await panel.getByRole('button', { name: 'Reload' }).click();
    await expect(panel.locator('.bm-gpo-cat').first()).toBeVisible({ timeout: 90_000 });
    await page.waitForTimeout(3_000);
    for (const cat of await panel.locator('.bm-gpo-cat').all()) {
      await cat.click();
      await page.waitForTimeout(300);
      if (await file.isVisible()) return file;
    }
  }
  return file;
}

/** The redis.conf pane of Management → Configuration → Settings, read live (Reload). */
async function openRedisConf(page: Page, id: string, family: string) {
  await openHostTab(page, id, 'management');
  const panel = await openSnapin(page, 'Settings');
  await expect(panel.getByRole('button', { name: 'Reload' })).toBeVisible({ timeout: 60_000 });
  // The file sits under whichever category the catalog files it in; find the category that holds it.
  const file = await findConfigFile(page, panel, REDIS_CONF);
  // Regression (fixed, RedHat family): config discovery followed only ENABLED units and man pages; RPM packages
  // never enable their daemon and EL images ship no man pages, so no package config was found. It now also reads
  // the package database's declared config files (rpm -qcf / dpkg conffiles) of every installed unit.
  await expect(file, `${REDIS_CONF} is part of the host document`).toBeVisible();
  await file.click();
  await expect(panel.locator('code.bm-cfg-path')).toHaveText(REDIS_CONF);
  return panel;
}

function settingRow(panel: Locator, key: string) {
  return panel.locator('table.bm-gpo-settings tbody tr').filter({ has: panel.page().locator('td.bm-gpo-key', { hasText: new RegExp(`^${key}$`) }) });
}

/** Set one key through the per-key setting dialog: Configured = value, or Host based (policy removed). */
async function setSetting(panel: Locator, key: string, value: string | null) {
  await settingRow(panel, key).click();
  const dlg = panel.locator('app-host-setting-dialog');
  await expect(dlg).toBeVisible();
  if (value === null) {
    await dlg.getByRole('radio', { name: /Host based/ }).check();
  } else {
    await dlg.getByRole('radio', { name: 'Configured' }).check();
    const sel = dlg.locator('select.bm-setting-val');
    if (await sel.count()) await sel.selectOption(value); else await dlg.locator('input.bm-setting-val').fill(value);
  }
  await dlg.getByRole('button', { name: /^Apply/ }).click();
  await expect(dlg).toHaveCount(0, { timeout: 120_000 });
}

async function generationNumbers(panel: Locator): Promise<number[]> {
  const cells = await panel.locator('table.bm-cfg-gen tbody tr td:first-child').allInnerTexts();
  return cells.map((c) => Number(c.trim())).filter((n) => !Number.isNaN(n));
}

async function topGeneration(ins: Locator): Promise<number> {
  const firsts = await ins.locator('table.bm-ri-gen tr td:first-child').allInnerTexts();
  return Math.max(0, ...firsts.map((t) => Number(t.replace('#', '').trim())).filter((n) => !Number.isNaN(n)));
}

/** Re-select the package so the inspector observes the host again (the State tab shows the last read). */
async function reobserve(page: Page, ins: Locator) {
  const name = (await ins.locator('.bm-ri-name').innerText()).trim();
  const mine = page.locator('button.bm-hr-item').filter({ has: page.locator('.bm-hr-name', { hasText: new RegExp(`^${name}$`) }) });
  // Selecting the same row again is not a new selection — step to another row and back.
  await page.locator('button.bm-hr-item').filter({ hasNot: page.locator('.bm-hr-name', { hasText: new RegExp(`^${name}$`) }) }).first().click();
  await expect(ins.locator('.bm-ri-name')).not.toHaveText(name);
  await mine.click();
  await expect(ins.locator('.bm-ri-name')).toHaveText(name);
  await expect(ins.locator('.bm-ri-busy')).toHaveCount(0, { timeout: 120_000 });
}

function genRow(ins: Locator, n: number) {
  return ins.locator('table.bm-ri-gen tr').filter({ has: ins.page().locator('td', { hasText: new RegExp(`^#${n}$`) }) });
}

// ── one serial scenario per host ──────────────────────────────────────────────────────────────────────────

for (const H of HOSTS) {
  test.describe(`${H.name} (${H.family})`, () => {
    test.describe.configure({ mode: 'serial' });
    let page: Page;
    let ctx: APIRequestContext;
    let id: string;
    let absentGen = 0;

    test.beforeAll(async ({ browser }) => {
      test.setTimeout(900_000);
      ctx = await api();
      id = (await agentByName(ctx, H.name))?.id;
      page = await newPage(browser);
      if (!id) return;
      // Fixture reset (API, not the UI under test): start from a host WITHOUT the scenario's packages, so the
      // console install and the wizard (which greys out installed roles) have something to do.
      const pkgs = [H.redis, H.memcached, ROLE.pkg];
      await ctx.post(`/api/v1/agents/${id}/tools/package`, {
        data: { params: { name: pkgs, state: 'absent' }, timeout_seconds: 600 }, timeout: 650_000,
      });
      if (H.family === 'debian') {
        // A removed Debian package stays in dpkg as "rc" (config files), and package_facts reports that as
        // installed (bug pinned below) — purge the leftovers so the wizard does not see them as installed.
        await ctx.post(`/api/v1/agents/${id}/tools/shell`, {
          data: { params: { cmd: `dpkg -l ${pkgs.join(' ')} redis-tools 2>/dev/null | awk '/^rc/ {print $2}' | xargs -r dpkg --purge` }, timeout_seconds: 300 },
          timeout: 330_000,
        });
      }
      // Re-read the installed inventory now (the stored one is refreshed by the poller every 6 h).
      await ctx.get(`/api/v1/agents/${id}/package-wizard/context?refresh=true`, { timeout: 120_000 });
    });

    test.afterAll(async () => {
      // Safety net only — the last test removes everything through the UI.
      if (id) {
        await ctx.post(`/api/v1/agents/${id}/tools/package`, {
          data: { params: { name: [H.redis, H.memcached, ROLE.pkg], state: 'absent' }, timeout_seconds: 600 },
          timeout: 650_000,
        }).catch(() => undefined);
      }
      await page?.context().close();
    });

    test('(a) console: Install a package… previews, then installs redis and memcached', async () => {
      test.skip(!id, `${H.name} is not enrolled`);
      test.setTimeout(600_000);
      await openInstalledPackages(page, H.name);
      await packageForm(page, [H.redis, H.memcached], 'present', true);
      const last = page.locator('.bm-form .bm-last');
      await expect(last).toHaveText(/^preview: /, { timeout: 300_000 });
      await expect(page.locator('.bm-form')).toBeVisible();   // a preview leaves the form open

      await packageForm(page, [H.redis, H.memcached], 'present', false);
      await expect(page.locator('.bm-form')).toHaveCount(0, { timeout: 540_000 });   // an apply closes it
      await expect(page.locator('.bm-result-head')).toContainText(`row(s) · ${H.name}`, { timeout: 120_000 });
      for (const pkg of [H.redis, H.memcached]) {
        const row = await packageRow(page, pkg);
        await expect(row, `${pkg} is listed as installed`).toHaveCount(1, { timeout: 60_000 });
        await expect(row.locator('td').nth(1), `${pkg} has a version`).not.toHaveText('');
      }
    });

    test('(b) Add roles wizard: a role not on this family is greyed out with the reason', async () => {
      test.setTimeout(180_000);
      const panel = await openRolesFeatures(page, id);
      await panel.getByRole('button', { name: /Add roles and features/ }).click();
      const dlg = page.getByRole('dialog');
      await expect(dlg.getByRole('heading', { name: 'Before you begin' })).toBeVisible();
      await expect(dlg).toContainText(`Detected OS family: ${H.family}`);
      // Previous on the first step is greyed out — with its reason.
      expect(await reasonOf(dlg.getByRole('button', { name: 'Previous' }))).toBe('This is the first step');
      await dlg.getByRole('button', { name: 'Next' }).click();
      await expect(dlg.getByRole('heading', { name: 'Select roles' })).toBeVisible();
      // Next is greyed out until a role is picked, and says so.
      expect(await reasonOf(dlg.getByRole('button', { name: 'Next' }))).toBe('Pick at least one role to install');

      await dlg.getByPlaceholder('Search roles…').fill(H.notOnFamily.label);
      const off = dlg.locator('.bm-wz-mrole').filter({ hasText: H.notOnFamily.label });
      await expect(off).toHaveCount(1);
      await expect(off.locator('input[type=checkbox]')).toBeDisabled();
      await expect(off.locator('.bm-wz-badge--off')).toHaveText(`Not on ${H.family}`);
      await off.click();
      const why = dlg.locator('.bm-wz-desc .bm-wz-warn--block');
      await expect(why, 'the description pane names the reason').toBeVisible();
      await expect(why).toHaveText(H.notOnFamily.reason);
      await dlg.getByRole('button', { name: 'Cancel' }).click();
      await expect(dlg).toHaveCount(0);
    });

    test('(b) Add roles wizard: required site values grey out Validate and Install, naming the fields', async () => {
      test.skip(H.family !== 'debian', 'iodined is offered on Debian');
      test.setTimeout(240_000);
      const panel = await openRolesFeatures(page, id);
      await panel.getByRole('button', { name: /Add roles and features/ }).click();
      const dlg = page.getByRole('dialog');
      await dlg.getByRole('button', { name: 'Next' }).click();
      await dlg.getByPlaceholder('Search roles…').fill('iodine');
      const row = dlg.locator('.bm-wz-mrole').filter({ hasText: 'iodined' }).first();
      await row.click();
      await row.locator('input[type=checkbox]').check();
      await dlg.getByRole('button', { name: 'Next' }).click();
      await expect(dlg.getByRole('heading', { name: /Configure iodined/ })).toBeVisible();
      const field = (label: string) => dlg.locator('.bm-pf-field').filter({ has: page.locator('.bm-pf-label', { hasText: new RegExp(`^${label}`) }) });
      // The three site values are marked required (*) in the form.
      for (const l of ['Tunnel Ip', 'Topdomain', 'Password']) await expect(field(l).locator('.bm-pf-req')).toHaveText('*', { timeout: 60_000 });
      await dlg.getByRole('button', { name: 'Next' }).click();
      await expect(dlg.getByRole('heading', { name: 'Confirmation' })).toBeVisible();
      const validate = dlg.getByRole('button', { name: /Validate \(dry run\)/ });
      const install = dlg.getByRole('button', { name: 'Install', exact: true });
      await expect(validate).toBeDisabled();
      await expect(install).toBeDisabled();
      expect(await reasonOf(validate)).toBe('Required settings are empty — iodined: password, topdomain, tunnel_ip');
      expect(await reasonOf(install)).toBe('Required settings are empty — iodined: password, topdomain, tunnel_ip');
      // Fill them in: both actions become available.
      await dlg.getByRole('button', { name: 'Previous' }).click();
      await field('Tunnel Ip').locator('input').fill('10.53.0.1/27');
      await field('Topdomain').locator('input').fill('t.example.test');
      await field('Password').locator('input').fill('e2e-tunnel-secret');
      await dlg.getByRole('button', { name: 'Next' }).click();
      await expect(validate).toBeEnabled();
      await expect(install).toBeEnabled();
      await dlg.getByRole('button', { name: 'Cancel' }).click();
      await expect(dlg).toHaveCount(0);
    });

    test('(b) Add roles wizard: a field this family\'s file lacks is greyed out with the reason', async () => {
      test.skip(H.family !== 'redhat', 'squid ships 3 directives on AlmaLinux, 207 documented on Debian');
      test.setTimeout(240_000);
      const panel = await openRolesFeatures(page, id);
      await panel.getByRole('button', { name: /Add roles and features/ }).click();
      const dlg = page.getByRole('dialog');
      await dlg.getByRole('button', { name: 'Next' }).click();
      await dlg.getByPlaceholder('Search roles…').fill('squid');
      const row = dlg.locator('.bm-wz-mrole').filter({ hasText: 'Squid Proxy' }).filter({ hasNotText: 'chasquid' }).first();
      await row.click();
      await row.locator('input[type=checkbox]').check();
      await dlg.getByRole('button', { name: 'Next' }).click();
      await expect(dlg.getByRole('heading', { name: /Configure/ })).toBeVisible();
      const field = (label: string) => dlg.locator('.bm-pf-field').filter({ has: page.locator('.bm-pf-label', { hasText: new RegExp(`^${label}`) }) });
      await dlg.getByRole('button', { name: /^Advanced/ }).click();   // fields with a shipped default sit there
      await expect(field('Http Port')).toBeVisible({ timeout: 60_000 });
      // http_port is in AlmaLinux's squid.conf: free. cache_mem is not: disabled, with the reason on the field.
      // Playwright treats only form controls as disableable, so the control inside the field is checked.
      await expect(field('Http Port').locator('input, select, textarea').first()).toBeEnabled();
      const off = field('Cache Mem');
      await expect(off.locator('input, select, textarea').first()).toBeDisabled();
      expect(await off.getAttribute('data-reason')).toBe("Not in this host's redhat file (/etc/squid/squid.conf) — a value here would be refused");
      await dlg.getByRole('button', { name: 'Cancel' }).click();
      await expect(dlg).toHaveCount(0);
    });

    test('(b) Add roles wizard: HAProxy configured (enum dropdowns), validated, installed', async () => {
      test.setTimeout(600_000);
      const panel = await openRolesFeatures(page, id);
      await panel.getByRole('button', { name: /Add roles and features/ }).click();
      const dlg = page.getByRole('dialog');
      await dlg.getByRole('button', { name: 'Next' }).click();
      await dlg.getByPlaceholder('Search roles…').fill(ROLE.search);
      const row = dlg.locator('.bm-wz-mrole').filter({ hasText: ROLE.label });
      await expect(row).toHaveCount(1);
      await row.click();
      await expect(dlg.locator('.bm-wz-desc')).toContainText(`Package: ${ROLE.pkg}`);
      await row.locator('input[type=checkbox]').check();
      await expect(dlg.locator('.bm-wz-steps')).toContainText(`Configure ${ROLE.label}`);
      await dlg.getByRole('button', { name: 'Next' }).click();

      await expect(dlg.getByRole('heading', { name: `Configure ${ROLE.label}` })).toBeVisible();
      // Enum fields are dropdowns whose options read as words (label, or the value itself), never blank.
      const selects = dlg.locator('.bm-wz-main select');
      await expect(selects.first()).toBeVisible({ timeout: 60_000 });
      expect(await selects.count()).toBeGreaterThanOrEqual(3);
      for (const s of await selects.all()) {
        const opts = await s.locator('option').allInnerTexts();
        expect(opts.length).toBeGreaterThan(1);
        for (const o of opts) expect(o.trim(), 'an enum option shows a label').not.toBe('');
        expect(await s.inputValue(), 'the default is one of the options').not.toBe('');
      }
      const balance = selects.nth(ROLE.enumIndex);
      expect(await balance.locator('option').allInnerTexts()).toContain(ROLE.enumValue);
      await balance.selectOption(ROLE.enumValue);
      await dlg.getByRole('button', { name: 'Next' }).click();

      await expect(dlg.getByRole('heading', { name: 'Confirmation' })).toBeVisible();
      await expect(dlg.locator('.bm-wz-sum')).toContainText(ROLE.pkg);
      await expect(dlg.locator('.bm-wz-sum')).toContainText('/etc/haproxy/haproxy.cfg');
      for (const label of await disabledWithoutReasonIn(dlg)) throw new Error(`disabled without a reason: ${label}`);

      await dlg.getByRole('button', { name: /Validate \(dry run\)/ }).click();
      await expect(dlg.locator('.bm-wz-dry')).toContainText(new RegExp(`${ROLE.label}: \\d+ step\\(s\\)`), { timeout: 300_000 });

      await dlg.getByRole('button', { name: 'Install', exact: true }).click();
      await expect(dlg.getByRole('heading', { name: 'Results' })).toBeVisible({ timeout: 60_000 });
      await expect(dlg.getByRole('button', { name: 'Close', exact: true })).toBeVisible({ timeout: 540_000 });
      const result = dlg.locator('.bm-wz-result').filter({ hasText: ROLE.label });
      await expect(result.locator('mat-icon.bm-err')).toHaveCount(0);
      await expect(result.locator('mat-icon.bm-ok').first()).toBeVisible();
      await dlg.getByRole('button', { name: 'Close', exact: true }).click();
      await expect(dlg).toHaveCount(0);
      // Closing the wizard re-reads the host's installed packages live (context?refresh=true); wait for that
      // here — the snap-in's own Refresh does not re-read them (stored inventory, 6 h poller cadence).
      const roleRow = panel.locator('table.bm-rf-tbl tbody tr').filter({ hasText: ROLE.label });
      await expect(roleRow).toHaveCount(1, { timeout: 120_000 });
    });

    test('(b) the deployment is listed in /role-deployments and the host role reads Compliant', async () => {
      test.setTimeout(420_000);
      const panel = await openRolesFeatures(page, id);
      const roleRow = panel.locator('table.bm-rf-tbl tbody tr').filter({ hasText: ROLE.label });
      await expect.poll(async () => {
        await panel.getByRole('button', { name: 'Refresh' }).first().click().catch(() => undefined);
        await page.waitForTimeout(3_000);
        return (await roleRow.count()) ? (await roleRow.locator('td').nth(4).innerText()).trim() : 'not listed';
      }, { message: `${ROLE.label} on ${H.name} reads Compliant`, timeout: 360_000, intervals: [5_000] }).toBe('Compliant');

      await page.goto('/role-deployments');
      await expect(page.getByRole('heading', { name: 'Role deployments', level: 1 })).toBeVisible();
      const card = page.locator('mat-card.rd-deployment')
        .filter({ hasText: `Roles & Features — ${H.name}` })
        .filter({ has: page.getByRole('row').filter({ hasText: ROLE.label }).filter({ hasText: 'compliant' }) });
      await expect(card.first()).toBeVisible({ timeout: 60_000 });
      await expect(card.first().locator('.rd-status')).toHaveText(/Active/);
      for (const label of await disabledWithoutReasonIn(page.locator('main'))) throw new Error(`/role-deployments: disabled without a reason: ${label}`);
    });

    test('(d) Configuration: a redis.conf value changed and applied appears as a new generation', async () => {
      test.setTimeout(420_000);
      const panel = await openRedisConf(page, id, H.family);
      const row = settingRow(panel, 'loglevel');
      await expect(row).toHaveCount(1);
      await expect(row.locator('td').nth(2)).toHaveText(/notice|verbose/);
      const before = await generationNumbers(panel);

      await setSetting(panel, 'loglevel', 'verbose');
      await expect(settingRow(panel, 'loglevel')).toContainText('Configured', { timeout: 120_000 });
      await expect(settingRow(panel, 'loglevel').locator('td').nth(2)).toHaveText('verbose');
      await expect.poll(async () => Math.max(0, ...(await generationNumbers(panel))), { timeout: 60_000 })
        .toBeGreaterThan(Math.max(0, ...before));
      await expect(panel.locator('table.bm-cfg-gen tr.bm-gen-current')).toContainText('current');
    });

    test('(d) Configuration: rolling back to the previous generation would revert that change', async () => {
      // Regression (fixed): a rollback re-applied only the target generation's own file, so rolling back past the
      // redis.conf change read "No changes". Each generation now records the before-image of every file it
      // changed, and rolling back to #N restores every file changed after #N.
      test.setTimeout(300_000);
      const panel = page.getByRole('tabpanel');
      const gens = await generationNumbers(panel);
      test.skip(gens.length < 2, 'no earlier generation on this host to roll back to');
      const current = Math.max(...gens);
      await panel.getByRole('button', { name: `Roll back to #${current - 1}…` }).click();
      const card = panel.locator('mat-card.bm-rollback');
      await expect(card).toContainText('dry-run preview, nothing applied yet');
      await expect(card.locator('table.bm-diff, p.bm-dim').first()).toBeVisible({ timeout: 120_000 });
      await expect(card.locator('table.bm-diff')).toContainText(REDIS_CONF, { timeout: 5_000 });
    });

    test('(d) Configuration: the greyed-out "Apply rollback" says why', async () => {
      // Regression (fixed): "Apply rollback" was disabled without a title/bm-why — a refusal without its reason.
      const card = page.getByRole('tabpanel').locator('mat-card.bm-rollback');
      test.skip(!(await card.isVisible()), 'no rollback preview open');
      const btn = card.getByRole('button', { name: 'Apply rollback' });
      test.skip(await btn.isEnabled(), 'the rollback has changes to apply on this host');
      expect(await reasonOf(btn)).not.toBe('');
    });

    test('(d) Configuration: the value is put back and the host policy removed', async () => {
      test.setTimeout(300_000);
      const panel = page.getByRole('tabpanel');
      const card = panel.locator('mat-card.bm-rollback');
      if (await card.isVisible()) await card.getByRole('button', { name: 'Cancel' }).click();
      await setSetting(panel, 'loglevel', 'notice');
      await expect(settingRow(panel, 'loglevel').locator('td').nth(2)).toHaveText('notice', { timeout: 120_000 });
      await setSetting(panel, 'loglevel', null);
      await expect(settingRow(panel, 'loglevel').locator('td').nth(1)).toHaveText('Host based', { timeout: 120_000 });
    });

    test('(c) Resources → Packages: haproxy planned and applied absent, recorded as a generation', async () => {
      test.setTimeout(420_000);
      await openHostTab(page, id, 'resources');
      await page.locator('.bm-hr-kind', { hasText: 'Packages' }).click();
      const item = page.locator('button.bm-hr-item').filter({ has: page.locator('.bm-hr-name', { hasText: new RegExp(`^${ROLE.pkg}$`) }) });
      await expect(item).toHaveCount(1, { timeout: 60_000 });
      await item.click();
      const ins = page.locator('app-resource-inspector');
      await expect(ins.locator('.bm-ri-name')).toHaveText(ROLE.pkg);
      await ins.getByRole('tab', { name: 'State' }).click();
      await expect(ins.getByRole('tabpanel').locator('.bm-ri-kv')).toContainText(/state\s*present/, { timeout: 60_000 });

      await ins.getByRole('tab', { name: 'Generations' }).click();
      await page.waitForTimeout(2_000);
      const genBefore = await topGeneration(ins);
      await ins.getByRole('tab', { name: 'Values' }).click();
      await ins.getByRole('button', { name: /Advanced/ }).click();
      await ins.getByRole('tabpanel').locator('select').first().selectOption('absent');
      await ins.getByRole('tab', { name: 'Preview' }).click();
      await ins.getByRole('button', { name: 'Preview changes' }).click();
      await expect(ins.getByRole('tabpanel').locator('.bm-ri-action')).toHaveText(/update · 1 field/, { timeout: 120_000 });
      await expect(ins.getByRole('tabpanel').locator('.bm-ri-kv')).toContainText(/state\s*present\s*→\s*absent/);
      await ins.getByRole('button', { name: 'Apply' }).click();
      await expect(ins.locator('.bm-ri-busy')).toHaveCount(0, { timeout: 300_000 });
      await expect(ins.locator('.bm-ri-err')).toHaveCount(0);
      await ins.getByRole('tab', { name: 'Generations' }).click();
      // The apply is recorded as a NEW generation (numbers continue across runs: wait for it to appear).
      await expect.poll(() => topGeneration(ins), { timeout: 120_000 }).toBeGreaterThan(genBefore);
      absentGen = await topGeneration(ins);
    });

    test('(c) Resources → Packages: the State tab reports haproxy absent after the removal', async () => {
      // Regression (fixed, Debian): package_facts counted dpkg "rc" packages (removed, config files left) as
      // installed, so a removal could never be observed and a following "present" planned as noop.
      test.setTimeout(120_000);
      const ins = page.locator('app-resource-inspector');
      await ins.getByRole('tab', { name: 'State' }).click();
      await expect(ins.getByRole('tabpanel').locator('.bm-ri-kv, .bm-ri-dim').first()).toBeVisible({ timeout: 60_000 });
      await expect(ins.getByRole('tabpanel')).toContainText(/state\s*absent|Not present on the host yet/, { timeout: 10_000 });
    });

    test('(c) Resources → Packages: present again, then rollback to the absent generation and back', async () => {
      test.setTimeout(600_000);
      const ins = page.locator('app-resource-inspector');
      await ins.getByRole('tab', { name: 'Values' }).click();
      const adv = ins.getByRole('button', { name: /Advanced/ });
      if (!(await ins.getByRole('tabpanel').locator('select').count())) await adv.click();
      await ins.getByRole('tabpanel').locator('select').first().selectOption('present');
      await ins.getByRole('tab', { name: 'Preview' }).click();
      await ins.getByRole('button', { name: 'Preview changes' }).click();
      await expect(ins.getByRole('tabpanel').locator('.bm-ri-action')).toHaveText(/update · 1 field/, { timeout: H.family === 'debian' ? 30_000 : 120_000 });
      await ins.getByRole('button', { name: 'Apply' }).click();
      await expect(ins.locator('.bm-ri-busy')).toHaveCount(0, { timeout: 400_000 });
      await ins.getByRole('tab', { name: 'Generations' }).click();
      await expect.poll(() => topGeneration(ins), { timeout: 60_000 }).toBeGreaterThan(absentGen);
      const presentGen = await topGeneration(ins);
      // Restore the absent generation — a rollback is recorded as a new generation with its note.
      await genRow(ins, absentGen).getByRole('button', { name: 'Restore' }).click();
      await expect(ins.locator('.bm-ri-busy')).toHaveCount(0, { timeout: 400_000 });
      await expect(ins.locator('table.bm-ri-gen')).toContainText(`rollback to gen ${absentGen}`, { timeout: 300_000 });
      await reobserve(page, ins);
      await ins.getByRole('tab', { name: 'State' }).click();
      await expect(ins.getByRole('tabpanel')).toContainText(/state\s*absent|Not present on the host yet/, { timeout: 60_000 });
      // …and forward again to the present generation so the role can be removed cleanly below.
      await ins.getByRole('tab', { name: 'Generations' }).click();
      await genRow(ins, presentGen).getByRole('button', { name: 'Restore' }).click();
      await expect(ins.locator('.bm-ri-busy')).toHaveCount(0, { timeout: 400_000 });
      await expect(ins.locator('table.bm-ri-gen')).toContainText(`rollback to gen ${presentGen}`, { timeout: 300_000 });
      await reobserve(page, ins);
      await ins.getByRole('tab', { name: 'State' }).click();
      await expect(ins.getByRole('tabpanel')).toContainText(/state\s*present/, { timeout: 60_000 });
    });

    test('cleanup: the role is uninstalled and redis/memcached removed through the UI', async () => {
      test.setTimeout(600_000);
      const panel = await openRolesFeatures(page, id);
      const roleRow = panel.locator('table.bm-rf-tbl tbody tr').filter({ hasText: ROLE.label });
      if (await roleRow.count()) {
        await roleRow.getByRole('button', { name: /Remove/ }).click();
        await roleRow.getByRole('button', { name: 'Uninstall' }).click();
        await expect(panel.locator('.bm-rf-msg')).toContainText(/uninstalled|no longer managed|failed/, { timeout: 400_000 });
        await expect(panel.locator('.bm-rf-msg')).not.toHaveClass(/err/);
      }
      await openInstalledPackages(page, H.name);
      await packageForm(page, [H.redis, H.memcached], 'absent', false);
      await expect(page.locator('.bm-form')).toHaveCount(0, { timeout: 540_000 });
    });

    test('the console no longer lists the removed packages', async () => {
      // Regression (fixed, Debian): package_facts listed dpkg "rc" packages (removed, config files remaining)
      // as installed.
      test.setTimeout(180_000);
      await page.getByRole('button', { name: 'Refresh' }).click();
      await expect(page.locator('.bm-result-head')).toContainText(`row(s) · ${H.name}`, { timeout: 120_000 });
      const rows = await packageRow(page, H.memcached);
      await expect(page.locator('.bm-table tbody tr').first()).toBeVisible();
      await expect(rows).toHaveCount(0, { timeout: 10_000 });
    });
  });
}

test.describe('catalog findings that need no install', () => {
  test('memcached: the template bound to /etc/memcached.conf renders a memcached.conf', async ({ browser }) => {
    // Regression (fixed): the catalog bound template "memcached" (the /etc/default/memcached shape,
    // ENABLE_MEMCACHED=yes) to /etc/memcached.conf; it now binds memcached.conf, and both templates record
    // their target so the index refuses the wrong pairing.
    test.setTimeout(600_000);
    const ctx = await api();
    const id = (await agentByName(ctx, 'e2e-deb-2'))?.id;
    test.skip(!id, 'e2e-deb-2 is not enrolled');
    const page = await newPage(browser);
    try {
      // memcached on e2e-deb-2 (the second Debian host, so e2e-deb-1's flow is untouched), by the console.
      await openInstalledPackages(page, 'e2e-deb-2');
      await packageForm(page, ['memcached'], 'present', false);
      await expect(page.locator('.bm-form')).toHaveCount(0, { timeout: 540_000 });

      await openHostTab(page, id, 'management');
      const panel = await openSnapin(page, 'Settings');
      await expect(panel.getByRole('button', { name: 'Reload' })).toBeVisible({ timeout: 60_000 });
      const file = await findConfigFile(page, panel, '/etc/memcached.conf');
      await expect(file, '/etc/memcached.conf is part of the host document').toBeVisible();
      await file.click();
      await panel.getByRole('button', { name: 'Edit via template' }).click();
      const te = panel.locator('app-host-template-edit');
      await te.getByRole('button', { name: 'Preview (render)' }).click();
      const pre = te.locator('pre');
      await expect(pre).not.toBeEmpty({ timeout: 60_000 });
      await expect(pre).toContainText(/^-m\s+\d+/m, { timeout: 5_000 });
    } finally {
      const cancel = page.locator('app-host-template-edit').getByRole('button', { name: 'Cancel' });
      if (await cancel.isVisible().catch(() => false)) await cancel.click();
      await ctx.post(`/api/v1/agents/${id}/tools/package`, {
        data: { params: { name: ['memcached'], state: 'absent' }, timeout_seconds: 600 }, timeout: 650_000,
      }).catch(() => undefined);
      await page.context().close();
    }
  });

  test('apache2 role: every enum field starts on one of its own options', async ({ browser }) => {
    // Regression (fixed): install-apache2 declared keepalive enum ["On","Off"] with default `true` (YAML read the
    // unquoted On as a bool) — a default outside its own value set.
    test.setTimeout(180_000);
    const ctx = await api();
    const id = (await agentByName(ctx, 'e2e-deb-1'))?.id;
    test.skip(!id, 'e2e-deb-1 is not enrolled');
    const page = await newPage(browser);
    try {
      const panel = await openRolesFeatures(page, id);
      await panel.getByRole('button', { name: /Add roles and features/ }).click();
      const dlg = page.getByRole('dialog');
      await dlg.getByRole('button', { name: 'Next' }).click();
      await dlg.getByPlaceholder('Search roles…').fill('Apache HTTP');
      const row = dlg.locator('.bm-wz-mrole').filter({ hasText: 'Apache HTTP Server' });
      await row.locator('input[type=checkbox]').check();
      await dlg.getByRole('button', { name: 'Next' }).click();
      await expect(dlg.getByRole('heading', { name: 'Configure Apache HTTP Server' })).toBeVisible();
      // The param form opens its "Advanced" list by itself when every field has a default; open it only
      // when it is still closed.
      await expect(dlg.getByRole('button', { name: /Advanced/ })).toBeVisible({ timeout: 60_000 });
      const keepaliveField = dlg.locator('.bm-pf-field').filter({ has: page.locator('label', { hasText: /^Keepalive$/ }) });
      if (!(await keepaliveField.count())) await dlg.getByRole('button', { name: /Advanced/ }).click();
      // Find the keepalive dropdown by its option set.
      const keepalive = dlg.locator('.bm-wz-main select').filter({ has: page.locator('option[value="On"]') }).first();
      await expect(keepalive).toBeVisible();
      expect(['On', 'Off']).toContain(await keepalive.inputValue());
    } finally {
      await page.getByRole('dialog').getByRole('button', { name: 'Cancel' }).click().catch(() => undefined);
      await page.context().close();
    }
  });
});

test.describe('e2e-deb-ro (enrolled read-only)', () => {
  test('a package install on a read-only host is refused, and the refusal names the reason', async ({ page }) => {
    // Regression (fixed): the console said the module was "missing or older than this console" — the opposite of
    // the real reason, the closed write gate — and the API relayed the agent's 403 as 502. The host now publishes
    // its write gate; the action names it, and a direct call answers 403 with the agent's own sentence.
    test.setTimeout(300_000);
    const ctx = await api();
    const ro = await agentByName(ctx, 'e2e-deb-ro');
    test.skip(!ro, 'e2e-deb-ro is not enrolled');
    await openInstalledPackages(page, 'e2e-deb-ro');
    const install = page.getByRole('button', { name: /Install a package/ });
    await expect(install).toBeVisible();
    expect(await reasonOf(install)).toMatch(/write|read-only|disabled/i);
    const res = await ctx.post(`/api/v1/agents/${ro.id}/tools/package`, {
      data: { params: { name: ['sl'], state: 'present', dry_run: true } }, timeout: 120_000,
    });
    expect(res.status(), 'the agent\'s refusal is relayed as a refusal, not a gateway fault').toBe(403);
    expect(JSON.stringify(await res.json())).toMatch(/write=false/);
  });

  test('on a read-only host the write action is greyed out with its reason before it is tried', async ({ page }) => {
    // Regression (fixed): the console offered "Install a package…" on a host whose write gate is off; the refusal
    // only came back after the call. Rule 2: an impossible action is greyed out with its reason up front.
    test.setTimeout(180_000);
    const ctx = await api();
    test.skip(!(await agentByName(ctx, 'e2e-deb-ro')), 'e2e-deb-ro is not enrolled');
    await openInstalledPackages(page, 'e2e-deb-ro');
    const install = page.getByRole('button', { name: /Install a package/ });
    await expect(install).toBeVisible();
    await expect(install).toBeDisabled({ timeout: 5_000 });
  });
});
