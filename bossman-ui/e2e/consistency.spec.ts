import { test, expect } from '@playwright/test';
import { mkdirSync, writeFileSync } from 'node:fs';
import { axe, disabledWithoutReason, limbo, overflow, settle, watch } from './support/checks';
import { concreteRoutes, declaredRoutes } from './support/routes';

// Every route of app.routes.ts, held to the same rules. Soft assertions: one screen reports ALL its problems, and
// the per-route JSON in test-results/consistency/ is the finding list docs/ui-e2e-findings.md is built from.
const resolved = concreteRoutes();
mkdirSync('test-results/consistency', { recursive: true });

test.describe('every screen', () => {
  for (const route of declaredRoutes()) {
    test(`/${route}`, async ({ page }) => {
      const r = (await resolved).find((x) => x.route === route)!;
      test.skip(!r.url, r.skip);
      const w = watch(page);
      await page.setViewportSize({ width: 1280, height: 800 });
      await page.goto(r.url!);
      await settle(page);
      const report = {
        route, url: r.url, landed: new URL(page.url()).pathname,
        consoleErrors: w.consoleErrors, failedRequests: w.failedRequests,
        axe: await axe(page), overflow1280: await overflow(page),
        disabledWithoutReason: await disabledWithoutReason(page), limbo: await limbo(page),
        overflow390: false,
      };
      await page.screenshot({ path: `test-results/consistency/${route.replace(/[/:]/g, '_')}.png`, fullPage: false });
      await page.setViewportSize({ width: 390, height: 844 });
      await page.waitForTimeout(300);
      report.overflow390 = await overflow(page);
      writeFileSync(`test-results/consistency/${route.replace(/[/:]/g, '_')}.json`, JSON.stringify(report, null, 2));

      expect.soft(report.landed, 'the route is not redirected away').not.toBe('/login');
      expect.soft(report.consoleErrors, 'console errors').toEqual([]);
      expect.soft(report.failedRequests, 'API calls answering 4xx/5xx').toEqual([]);
      expect.soft(report.axe, 'critical/serious accessibility violations').toEqual([]);
      expect.soft(report.overflow1280, 'horizontal scroll at 1280px').toBe(false);
      expect.soft(report.overflow390, 'horizontal scroll at 390px').toBe(false);
      expect.soft(report.disabledWithoutReason, 'disabled controls without a reason').toEqual([]);
      expect.soft(report.limbo, 'rendered undefined/NaN/[object Object]').toEqual([]);
    });
  }
});

test('every navigable route is reachable in at most two clicks, and the nav fits the viewport', async ({ page }) => {
  // 720px: the height the nav is designed for (app.scss .bm-nav-item) — a 13" laptop with browser chrome.
  await page.setViewportSize({ width: 1280, height: 720 });
  await page.goto('/fleet');
  await settle(page);
  const reachable = new Set<string>();
  const tooTall: string[] = [];
  const tabs = page.locator('.bm-ws-btn');
  for (let i = 0; i < (await tabs.count()); i++) {
    const label = (await tabs.nth(i).getAttribute('aria-label')) ?? '';
    await tabs.nth(i).click();                                            // click 1: the workspace
    await expect(page.locator('.bm-ws-name')).toHaveText(new RegExp(label, 'i'));
    for (const href of await page.locator('a.bm-nav-item').evaluateAll((as) => as.map((a) => a.getAttribute('href')))) {
      if (href) reachable.add(href.replace(/^\//, ''));                   // click 2: the item
    }
    const navTall = await page.locator('nav.bm-nav').evaluate((n) => n.scrollHeight > window.innerHeight + 1);
    if (navTall) tooTall.push(await tabs.nth(i).getAttribute('aria-label') ?? `tab ${i}`);
  }
  reachable.add('help');
  const unreachable = declaredRoutes().filter((r) => !r.includes(':') && !reachable.has(r));
  writeFileSync('test-results/consistency/_navigation.json', JSON.stringify({ reachable: [...reachable].sort(), unreachable, tooTall }, null, 2));
  expect.soft(unreachable, 'routes no nav path reaches in ≤2 clicks').toEqual([]);
  expect.soft(tooTall, 'workspaces whose nav is taller than the viewport').toEqual([]);
});
