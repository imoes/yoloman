import { readFileSync } from 'node:fs';
import { APIRequestContext, request } from '@playwright/test';
import { API_URL, authFile } from './env';

/**
 * Every route the app declares — read from app.routes.ts itself, so a new screen is crawled the day it is added and
 * no second list can drift from the router.
 */
export function declaredRoutes(): string[] {
  const src = readFileSync('src/app/app.routes.ts', 'utf8');
  // A redirect is not a screen: it has nothing to crawl and nothing the nav must reach (its target is checked).
  const paths = [...src.matchAll(/path:\s*'([^']*)'([^}]*)/g)].filter((m) => !m[2].includes('redirectTo')).map((m) => m[1]);
  return [...new Set(paths)].filter((p) => p && p !== '**' && p !== 'login');
}

/** The admin's bearer token, taken from the saved browser state of the setup project. */
export function adminToken(): string {
  const state = JSON.parse(readFileSync(authFile('admin'), 'utf8'));
  for (const origin of state.origins ?? []) {
    for (const item of origin.localStorage ?? []) {
      if (item.name === 'bossman_access_token') return item.value;
    }
  }
  throw new Error('no bossman_access_token in the admin storage state — run the setup project');
}

export async function api(): Promise<APIRequestContext> {
  return request.newContext({ baseURL: API_URL, extraHTTPHeaders: { Authorization: `Bearer ${adminToken()}` } });
}

async function first(ctx: APIRequestContext, url: string, pick: (body: any) => string | undefined) {
  const r = await ctx.get(url);
  if (!r.ok()) return undefined;
  try {
    return pick(await r.json());
  } catch {
    return undefined;
  }
}

const list = (b: any, key?: string): any[] => (Array.isArray(b) ? b : (key && Array.isArray(b?.[key]) ? b[key] : []));

/**
 * A concrete URL for each declared route, filling parameters from real data. A route whose parameter has no data on
 * this instance is returned with `skip` and the reason — reported, never silently dropped.
 */
export async function concreteRoutes(): Promise<{ route: string; url?: string; skip?: string }[]> {
  const ctx = await api();
  // A real host (an address, not a cluster pseudo-agent), so the host page shows what a host page shows.
  const agent = await first(ctx, '/api/v1/agents', (b) =>
    (list(b, 'agents').find((a) => a.address && a.mode !== 'cluster') ?? list(b, 'agents')[0])?.id);
  const cluster = await first(ctx, '/api/v1/kubernetes/clusters', (b) => list(b, 'clusters')[0]?.id);
  const run = await first(ctx, '/api/v1/runs?limit=1', (b) => list(b, 'runs')[0]?.id);
  const plan = await first(ctx, '/api/v1/plans', (b) => list(b, 'plans')[0]?.name);
  const values: Record<string, string | undefined> = {
    'hosts/:id': agent, 'console/:id': agent, 'kubernetes/:id': cluster, 'kubernetes/:id/apps/new': cluster,
    'runs/:id': run, 'plans/:name': plan,
  };
  return declaredRoutes().map((route) => {
    if (!route.includes(':')) return { route, url: `/${route}` };
    if (route === 'kubernetes/:id/apps/:namespace/:name') {
      return { route, skip: 'needs an application created by the Kubernetes scenario (covered there)' };
    }
    if (route === 'vm-console/:name') return { route, skip: 'needs a running VM (covered by the disk-template scenario)' };
    const v = values[route];
    if (!v) return { route, skip: `no data on this instance to fill ${route}` };
    return { route, url: '/' + route.replace(/:[a-z]+/, v) };
  });
}
