import AxeBuilder from '@axe-core/playwright';
import { Page } from '@playwright/test';

/**
 * The consistency and usability rules every screen is held to (CLAUDE.md "Formale Logik", docs/ui-workspaces.md):
 *
 *   consoleErrors        the screen raises no JavaScript error
 *   failedRequests       no API call answers 4xx/5xx while the screen loads (an error the UI swallows is still one)
 *   axe                  no critical/serious accessibility violation (WCAG A/AA via axe-core)
 *   overflow             no horizontal page scroll at desktop (1280) and phone (390) width
 *   disabledWithoutReason  every disabled control says WHY (title / tooltip / aria-describedby) — rule 4,
 *                        "zu jeder Verweigerung der Grund"
 *   limbo                no rendered "undefined", "NaN", "[object Object]", "Invalid Date" — rule 3, every value is
 *                        a named state, never an accident of the template
 */
export interface Watch {
  consoleErrors: string[];
  failedRequests: string[];
}

export function watch(page: Page): Watch {
  const w: Watch = { consoleErrors: [], failedRequests: [] };
  page.on('console', (m) => {
    if (m.type() === 'error') w.consoleErrors.push(m.text().slice(0, 300));
  });
  page.on('pageerror', (e) => w.consoleErrors.push(`pageerror: ${e.message.slice(0, 300)}`));
  page.on('response', (r) => {
    const url = r.url();
    if (r.status() >= 400 && url.includes('/api/')) w.failedRequests.push(`${r.status()} ${r.request().method()} ${url.replace(/^https?:\/\/[^/]+/, '')}`);
  });
  return w;
}

export async function settle(page: Page) {
  await page.waitForLoadState('domcontentloaded');
  // The app polls; networkidle may never come. Bounded wait, then measure what is there.
  await page.waitForLoadState('networkidle', { timeout: 8000 }).catch(() => undefined);
}

export async function axe(page: Page) {
  const res = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  const bad = res.violations.filter((v) => v.impact === 'critical' || v.impact === 'serious');
  return bad.map((v) => `${v.impact}: ${v.id} (${v.nodes.length}×) ${v.help} — at ${v.nodes.slice(0, 3)
    .map((n) => n.target.join(' ')).join(' | ')}`);
}

export async function overflow(page: Page): Promise<boolean> {
  return page.evaluate(() => {
    const el = document.scrollingElement ?? document.documentElement;
    return el.scrollWidth > el.clientWidth + 1;
  });
}

export async function disabledWithoutReason(page: Page): Promise<string[]> {
  return page.evaluate(() => {
    const out: string[] = [];
    const nodes = document.querySelectorAll('button:disabled, [aria-disabled="true"], .mat-mdc-button-disabled');
    nodes.forEach((n) => {
      const el = n as HTMLElement;
      if (!el.offsetParent) return; // not visible
      let cur: HTMLElement | null = el;
      for (let i = 0; i < 3 && cur; i++, cur = cur.parentElement) {
        if (cur.getAttribute('title') || cur.getAttribute('aria-describedby') || cur.getAttribute('data-reason')) return;
      }
      const label = (el.getAttribute('aria-label') || el.innerText || el.className).trim().slice(0, 60);
      out.push(label);
    });
    return [...new Set(out)];
  });
}

export async function limbo(page: Page): Promise<string[]> {
  return page.evaluate(() => {
    const text = document.body.innerText;
    const hits: string[] = [];
    for (const word of ['undefined', 'NaN', '[object Object]', 'Invalid Date']) {
      const re = new RegExp(`(^|[^\\w])${word.replace(/[[\]]/g, '\\$&')}([^\\w]|$)`);
      const m = text.match(re);
      if (m) {
        const at = text.indexOf(m[0]);
        hits.push(`${word}: “${text.slice(Math.max(0, at - 40), at + 40).replace(/\s+/g, ' ')}”`);
      }
    }
    return hits;
  });
}
