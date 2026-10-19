import { APIRequestContext, Locator, Page, expect } from '@playwright/test';

/**
 * Helpers shared by the scenario specs (kubernetes, packages): a run tag for unique names, the agent id of an
 * enrolled e2e host, the "every disabled control names its reason" probe scoped to a region, and approving a
 * change proposal through /change-proposals the way an operator does.
 */

/** A short, DNS-label-safe tag that makes every name a run creates unique (and findable for cleanup). */
export function runTag(): string {
  return Date.now().toString(36).slice(-6) + Math.floor(Math.random() * 36 * 36).toString(36).padStart(2, '0');
}

export async function agentByName(ctx: APIRequestContext, name: string): Promise<any | undefined> {
  const r = await ctx.get('/api/v1/agents');
  const body = await r.json();
  const list: any[] = Array.isArray(body) ? body : body.agents ?? [];
  return list.find((a) => a.name === name);
}

/**
 * Every VISIBLE disabled control inside `scope` must say why: a title / aria-describedby / data-reason on the
 * control or one of its three nearest ancestors (the app wraps disabled buttons in `span.bm-why[title]`).
 * Returns the labels of the controls that do not.
 */
export async function disabledWithoutReasonIn(scope: Locator): Promise<string[]> {
  return scope.evaluateAll((roots) => {
    const out: string[] = [];
    for (const root of roots) {
      root.querySelectorAll('button:disabled, [aria-disabled="true"], .mat-mdc-button-disabled').forEach((n) => {
        const el = n as HTMLElement;
        if (!el.offsetParent) return;
        for (let cur: HTMLElement | null = el, i = 0; cur && i < 4; cur = cur.parentElement, i++) {
          if (cur.getAttribute('title') || cur.getAttribute('aria-describedby') || cur.getAttribute('data-reason')) return;
        }
        out.push((el.getAttribute('aria-label') || el.innerText || el.className).trim().slice(0, 60));
      });
    }
    return [...new Set(out)];
  });
}

/** The reason a disabled control gives (its own or a near ancestor's title), '' when it gives none. */
export async function reasonOf(control: Locator): Promise<string> {
  return control.evaluate((el) => {
    for (let cur: HTMLElement | null = el as HTMLElement, i = 0; cur && i < 4; cur = cur.parentElement, i++) {
      const t = cur.getAttribute('title') || cur.getAttribute('data-reason');
      if (t) return t;
    }
    return '';
  });
}

/**
 * Approve the newest PENDING change proposal whose row text matches `title`, through the UI, and wait until it is
 * applied. Returns the detail pane text (preview + apply result) for the caller to assert on.
 */
export async function approveProposal(page: Page, title: RegExp | string, timeout = 180_000): Promise<string> {
  await page.goto('/change-proposals');
  await expect(page.getByRole('heading', { name: 'Change proposals', level: 1 })).toBeVisible();
  await page.locator('.pr-segbtn', { hasText: /^Pending$/ }).click();
  const row = page.locator('.pr-row').filter({ hasText: title }).first();
  await expect(row, `a pending proposal matching ${title}`).toBeVisible({ timeout: 30_000 });
  await row.click();
  const detail = page.locator('.pr-detail');
  await expect(detail.locator('.pr-badge')).toHaveText(/pending/i);
  page.once('dialog', (d) => d.accept());
  await detail.getByRole('button', { name: /Approve & apply/ }).click();
  await expect(detail.locator('.pr-badge').first()).toHaveText(/applied/i, { timeout });
  return detail.innerText();
}

/** Poll `probe` (which may click Refresh and read the page) until it returns true. */
export async function eventually(probe: () => Promise<boolean>, message: string, timeout = 180_000, every = 4_000) {
  await expect.poll(async () => {
    try {
      return await probe();
    } catch {
      return false;
    }
  }, { message, timeout, intervals: [every] }).toBe(true);
}
