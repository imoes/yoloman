import { test, expect, APIRequestContext } from '@playwright/test';
import { agentId, apiAs, callTool, ok, pageAs, tag } from './support/deploy-scenario';

/**
 * A diagnosis remedy as a change proposal (docs/diagnosis.md, plan B10), against the real Windows test host:
 * a service is created DISABLED on bossman-wintest, Bossman diagnoses it (svc.disabled, Proven, with a start-type
 * remedy), the remedy is filed as a proposal by one admin — who then sees "Approve" greyed with the four-eyes reason
 * — and a second admin approves it. Approval executes nothing: the service stays disabled and the result says so.
 */

test.describe.configure({ mode: 'serial' });
test.setTimeout(300_000);

const HOST = 'bossman-wintest';
const SVC = tag('diag').replace(/[^a-z0-9-]/gi, '').slice(0, 40);

let api: APIRequestContext;
let agent = '';

const ps = (script: string) => callTool(api, agent, 'powershell', { script });

test.beforeAll(async () => {
  api = await apiAs('admin');
  agent = await agentId(api, HOST);
  await ps(`sc.exe create ${SVC} binPath= "C:\\Windows\\System32\\cmd.exe" start= disabled | Out-Null; 'ok'`);
});

test.afterAll(async () => {
  await ps(`sc.exe delete ${SVC} 2>$null | Out-Null; 'ok'`).catch(() => undefined);
});

test('a remedy is proposed by one admin, greyed for them with the reason, approved by another — and never run', async ({ page, browser }) => {
  const diag = await ok<any>(api.post(`/api/v1/agents/${agent}/diagnose`, { data: { name: SVC, timeout_seconds: 120 } }), 'diagnose');
  expect(`${diag.leading_rule}/${diag.leading_certainty}`).toBe('svc.disabled/Proven');
  expect(diag.contract_status).toBe('ok');
  const filed = await ok<any>(api.post(`/api/v1/diagnoses/${diag.id}/propose`, { data: { finding: 0 } }), 'propose');

  // The proposer: the button is greyed BEFORE the click, and its title says why.
  await page.goto('/change-proposals');
  await page.locator('.pr-segbtn', { hasText: /^Pending$/ }).click();
  await page.locator('.pr-row').filter({ hasText: filed.title }).first().click();
  const mine = page.locator('.pr-detail').getByRole('button', { name: /Approve \(does not run it\)/ });
  await expect(mine).toBeDisabled();
  await expect(page.locator('.pr-detail .bm-why').first()).toHaveAttribute('title', /four-eyes/);
  await expect(page.locator('.pr-detail')).toContainText(`sc.exe config '${SVC}' start= demand`);

  // A second admin approves; the result says it was not executed.
  const { ctx, page: other } = await pageAs(browser, 'admin2');
  try {
    await other.goto('/change-proposals');
    await other.locator('.pr-segbtn', { hasText: /^Pending$/ }).click();
    await other.locator('.pr-row').filter({ hasText: filed.title }).first().click();
    other.once('dialog', (d) => d.accept());
    await other.locator('.pr-detail').getByRole('button', { name: /Approve \(does not run it\)/ }).click();
    await expect(other.locator('.pr-detail .pr-badge').first()).toHaveText(/approved/i);
    await expect(other.locator('.pr-detail')).toContainText('"executed": false');
  } finally {
    await ctx.close();
  }

  // And the host is untouched: still disabled.
  const again = await ok<any>(api.post(`/api/v1/agents/${agent}/diagnose`, { data: { name: SVC, timeout_seconds: 120 } }), 'diagnose again');
  expect(again.leading_rule).toBe('svc.disabled');
});

/** /mmc for one host with the Services node open, filtered to one service. */
async function servicesNode(page: import('@playwright/test').Page, host: string, service: string) {
  await page.setViewportSize({ width: 1600, height: 1000 });
  await page.goto('/mmc');
  // the option reads "<host> · <os family>" when the family is known
  const select = page.getByRole('combobox', { name: 'Host' });
  const option = select.locator('option').filter({ hasText: new RegExp(`^\\s*${host.replace(/[.]/g, '\\.')}( · |\\s*$)`) }).first();
  await expect(option).toHaveCount(1, { timeout: 30_000 });
  await select.selectOption({ label: ((await option.textContent()) ?? host).trim() });
  const snapin = page.locator('.bm-snapin').filter({ has: page.locator('.bm-sname', { hasText: /^Services$/ }) });
  await expect(snapin).toBeVisible({ timeout: 30_000 });
  if (!(await snapin.locator('button.bm-node').first().isVisible())) await snapin.locator('.bm-snapin-head').click();
  await snapin.locator('button.bm-node').first().click();
  await expect(page.locator('.bm-result-head')).toContainText(`row(s) · ${host}`, { timeout: 120_000 });
  await page.locator('input.bm-filter').fill(service);
  return page.locator('.bm-table tbody tr').filter({ has: page.getByRole('cell', { name: service, exact: true }) });
}

test('the services snap-in answers "why is it not running?" with evidence, an explanation, exports and a proposal', async ({ page }) => {
  const row = await servicesNode(page, HOST, SVC);
  await row.getByRole('button', { name: 'Why is it not running?' }).click();

  const panel = page.locator(`app-diagnosis-panel section[data-service="${SVC}"]`);
  const finding = panel.locator('article.dg-finding[data-rule="svc.disabled"]');
  await expect(finding).toBeVisible({ timeout: 120_000 });
  await expect(finding.locator('.dg-cert')).toHaveText('Proven');
  await finding.locator('details.dg-ev summary').click();
  await expect(finding.locator('.dg-evrow').first()).toContainText(`scm:config:${SVC}`);

  await panel.getByRole('button', { name: 'Explain' }).click();
  await expect(panel.locator('.dg-xhead').first()).toContainText('Proven: ');
  await expect(panel.locator('.dg-sent').first()).toBeVisible();
  await expect(panel.locator('.dg-unbacked')).toHaveCount(0);

  await finding.getByRole('button', { name: 'powershell' }).click();
  await expect(panel.locator('.dg-export')).toContainText(`sc.exe config '${SVC}' start= demand`);
  await finding.getByRole('button', { name: /Propose this repair/ }).click();
  await expect(panel.locator('.dg-ok')).toContainText('approving runs nothing');
});

test('on an agent without service_diagnose the action is greyed with the reason, before any click', async ({ page }) => {
  const old = (await ok<any>(api.get('/api/v1/agents'), 'agents'));
  const list: any[] = Array.isArray(old) ? old : old.agents ?? [];
  const legacy = list.find((a) => a.name === 'pve1.example.internal');
  test.skip(!legacy, 'the old Proxmox agent is not enrolled here');
  const row = (await servicesNode(page, 'pve1.example.internal', 'pveproxy')).first();
  const button = row.getByRole('button', { name: 'Why is it not running?' });
  await expect(button).toBeDisabled();
  await expect(button.locator('xpath=..')).toHaveAttribute('title', /no service_diagnose module/);
});

test('the same action answers for a systemd unit on a Linux host', async ({ page }) => {
  const all = await ok<any>(api.get('/api/v1/agents'), 'agents');
  const linux = (Array.isArray(all) ? all : all.agents ?? []).find((a: any) => a.name === 'host4.example.internal');
  test.skip(!linux, 'the local dev agent is not enrolled here');
  // fwupd-refresh: a oneshot unit that is not running between its timer runs — failed or stopped cleanly, either
  // way the panel must answer with a finding and its certainty, never with silence.
  const row = (await servicesNode(page, 'host4.example.internal', 'fwupd-refresh')).first();
  await row.getByRole('button', { name: 'Why is it not running?' }).click();
  const panel = page.locator('app-diagnosis-panel section[data-service="fwupd-refresh"]');
  await expect(panel.locator('article.dg-finding').first()).toBeVisible({ timeout: 120_000 });
  await expect(panel.locator('.dg-cert').first()).toHaveText(/^(Proven|Likely|Unknown)$/);
  await expect(panel.locator('.dg-summary')).toContainText('fwupd-refresh.service');
});
