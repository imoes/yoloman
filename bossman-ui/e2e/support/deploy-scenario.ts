import { readFileSync } from 'node:fs';
import { APIRequestContext, Browser, BrowserContext, Page, expect, request } from '@playwright/test';
import { API_URL, UserKey, authFile } from './env';

/**
 * Helpers shared by the role and deployment scenarios (roles.spec.ts, deployments.spec.ts).
 *
 * Every scenario names what it creates with `tag()` — unique per run — and removes it afterwards through the
 * API, so a failed run leaves rows that are recognisable by name rather than anonymous debris.
 */

export const RUN = Date.now().toString(36);
export const tag = (what: string) => `e2e-${what}-${RUN}`;

/** The bearer token of a suite account, from the storage state the setup project saved. */
export function tokenOf(user: UserKey): string {
  const state = JSON.parse(readFileSync(authFile(user), 'utf8'));
  for (const origin of state.origins ?? []) {
    for (const item of origin.localStorage ?? []) {
      if (item.name === 'bossman_access_token') return item.value;
    }
  }
  throw new Error(`no bossman_access_token in the ${user} storage state — run the setup project`);
}

export async function apiAs(user: UserKey): Promise<APIRequestContext> {
  return request.newContext({ baseURL: API_URL, extraHTTPHeaders: { Authorization: `Bearer ${tokenOf(user)}` } });
}

/** A second browser session (another account) next to the test's own page. */
export async function pageAs(browser: Browser, user: UserKey): Promise<{ ctx: BrowserContext; page: Page }> {
  const ctx = await browser.newContext({ storageState: authFile(user) });
  return { ctx, page: await ctx.newPage() };
}

export async function ok<T = any>(res: Promise<import('@playwright/test').APIResponse>, what: string): Promise<T> {
  const r = await res;
  expect(r.ok(), `${what}: ${r.status()} ${await r.text().catch(() => '')}`).toBeTruthy();
  const text = await r.text();
  return (text ? JSON.parse(text) : undefined) as T;
}

export async function agentId(api: APIRequestContext, name: string): Promise<string> {
  const body = await ok<any>(api.get('/api/v1/agents'), 'list agents');
  const list: any[] = Array.isArray(body) ? body : body.agents ?? [];
  const a = list.find((x) => x.name === name);
  expect(a, `test host ${name} is enrolled`).toBeTruthy();
  return a.id;
}

export async function yolo(api: APIRequestContext): Promise<boolean> {
  return (await ok<any>(api.get('/api/v1/system/yolo-mode'), 'read YOLO')).yolo_mode;
}
export async function setYolo(api: APIRequestContext, enabled: boolean): Promise<void> {
  await ok(api.put('/api/v1/system/yolo-mode', { data: { enabled } }), `set YOLO ${enabled}`);
}

/** Retire (stop managing) every deployment whose name carries this run's tag — the scenario cleanup. */
export async function retireTagged(api: APIRequestContext, behavior: 'unmanage' | 'uninstall' = 'unmanage') {
  const { deployments } = await ok<any>(api.get('/api/v1/role-deployments'), 'list deployments');
  for (const d of deployments) {
    if (d.name.includes(RUN) && d.status !== 'retired') {
      await api.post(`/api/v1/role-deployments/${d.id}/retire`, { data: { behavior } });
    }
  }
}

export async function deploymentByName(api: APIRequestContext, name: string): Promise<any> {
  const { deployments } = await ok<any>(api.get('/api/v1/role-deployments'), 'list deployments');
  return deployments.find((d: any) => d.name === name);
}

/** Run a tool on a host through the agent (the same path the UI's tool calls take). */
export async function callTool(api: APIRequestContext, agent: string, tool: string, params: Record<string, unknown>) {
  return ok<any>(api.post(`/api/v1/agents/${agent}/tools/${tool}`, { data: { params } }), `tool ${tool}`);
}

/**
 * Put text into the page's Monaco editor the way a paste does. Typing (even keyboard.insertText) runs Monaco's
 * auto-indent on every newline and shifts nested YAML; a paste event carries the text verbatim.
 */
export async function setMonaco(page: Page, container: string, text: string) {
  const ed = page.locator(container).locator('.monaco-editor').first();
  await ed.click();
  await page.keyboard.press('ControlOrMeta+A');
  await page.keyboard.press('Delete');
  await page.locator(container).locator('textarea').first().evaluate((ta, value) => {
    const dt = new DataTransfer();
    dt.setData('text/plain', value);
    ta.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
  }, text);
}

/** The reason a (disabled) control gives: its own title or the nearest wrapping `.bm-why[title]`. */
export async function why(control: import('@playwright/test').Locator): Promise<string> {
  return control.evaluate((el) => {
    for (let cur: HTMLElement | null = el as HTMLElement, i = 0; cur && i < 4; cur = cur.parentElement, i++) {
      const t = cur.getAttribute('title');
      if (t) return t;
    }
    return '';
  });
}

/** Poll an API-side condition until it holds (the deployment worker runs every 60 s; /reconcile is immediate). */
export async function until<T>(probe: () => Promise<T | undefined | false>, message: string, timeout = 240_000, every = 5_000): Promise<T> {
  let last: T | undefined | false;
  await expect.poll(async () => {
    try { last = await probe(); } catch { last = undefined; }
    return !!last;
  }, { message, timeout, intervals: [every] }).toBe(true);
  return last as T;
}

/**
 * A cross-worker mutex for fleet-global state (the YOLO switch, a host's write gate). Playwright runs spec files
 * in parallel workers; a scenario that flips YOLO on must not overlap one that expects a proposal. `mkdir` is
 * atomic, so the directory is the lock; a lock older than `staleMs` is taken over (a crashed worker).
 */
export async function withLock<T>(name: string, fn: () => Promise<T>, staleMs = 600_000): Promise<T> {
  const { mkdirSync, rmSync, statSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const dir = `${tmpdir()}/bossman-e2e-lock-${name}`;
  for (;;) {
    try {
      mkdirSync(dir);
      break;
    } catch {
      try {
        if (Date.now() - statSync(dir).mtimeMs > staleMs) rmSync(dir, { recursive: true, force: true });
      } catch { /* released meanwhile */ }
      await new Promise((r) => setTimeout(r, 1000));
    }
  }
  try {
    return await fn();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
