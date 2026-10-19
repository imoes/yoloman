import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

/**
 * Every page in the navigation, opened once: does it render, and does it render without errors?
 *
 * The page list is read from app.ts (WORKSPACES), so a new nav item is crawled without touching this file.
 * Per page it records the load time, browser console errors, uncaught page errors, every /api/ response with
 * status >= 400 and every visible alert, and saves a screenshot for a human look at whether the page makes sense.
 * The findings land in crawl-report/report.json. A 5xx or an uncaught page error fails the page; a 4xx or
 * a console error is recorded as a soft failure, because some are legitimate (an optional integration that is
 * not configured answers 404 or 409 by design) and each needs a judgement, not a blanket rule.
 */

const appTs = fs.readFileSync(path.join(__dirname, '../src/app/app.ts'), 'utf8');
const PAGES = [...appTs.matchAll(/\{ path: '([^']+)', label: '([^']+)'/g)].map((m) => ({ path: m[1], label: m[2] }));
// Outside test-results: Playwright empties that directory at the start of every run, which deleted the report.
const OUT = path.join(__dirname, '../crawl-report');
const report: Record<string, unknown>[] = [];

test.describe.configure({ mode: 'serial' });
test.setTimeout(60_000);

test.beforeAll(() => fs.mkdirSync(OUT, { recursive: true }));
test.afterAll(() => fs.writeFileSync(path.join(OUT, 'report.json'), JSON.stringify(report, null, 1)));

for (const p of PAGES) {
  test(`${p.label} (${p.path}) renders without errors`, async ({ page }) => {
    const consoleErrors: string[] = [];
    const pageErrors: string[] = [];
    const failed: { status: number; method: string; url: string; body: string }[] = [];
    page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text().slice(0, 300)); });
    page.on('pageerror', (e) => pageErrors.push(String(e).slice(0, 300)));
    page.on('response', async (r) => {
      if (r.url().includes('/api/') && r.status() >= 400) {
        let body = '';
        try { body = (await r.text()).slice(0, 200); } catch { /* body gone after navigation */ }
        failed.push({ status: r.status(), method: r.request().method(), url: r.url().replace(/^https?:\/\/[^/]+/, ''), body });
      }
    });

    const t0 = Date.now();
    await page.goto(p.path);
    await page.waitForLoadState('networkidle', { timeout: 20_000 }).catch(() => undefined);
    const ms = Date.now() - t0;
    await expect(page).not.toHaveURL(/\/login/);
    const alerts = (await page.locator('[role=alert], .error, .bm-wz-warn--block').allInnerTexts())
      .map((t) => t.trim()).filter(Boolean).map((t) => t.slice(0, 200));
    const slug = p.path.replace(/\//g, '_') || '_root';
    await page.screenshot({ path: path.join(OUT, `${slug}.png`), fullPage: false });

    report.push({ path: p.path, label: p.label, ms, consoleErrors, pageErrors, failed, alerts });

    expect(pageErrors, 'uncaught page errors').toEqual([]);
    expect(failed.filter((f) => f.status >= 500), 'API 5xx').toEqual([]);
    expect.soft(failed, 'API 4xx').toEqual([]);
    expect.soft(consoleErrors, 'console errors').toEqual([]);
  });
}
