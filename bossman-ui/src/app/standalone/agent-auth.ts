import { HttpInterceptorFn, HttpResponse } from '@angular/common/http';
import { signal } from '@angular/core';
import { map, tap } from 'rxjs';

/**
 * Auth + API glue for the standalone-agent UI (a second entry point that
 * reuses the fleet host components against the agent's OWN API).
 *
 * Two credential kinds, distinguished by scheme:
 * - a PAM **session** token from POST /api/v1/auth/login → `Authorization: Session <t>`
 * - the agent's static **bearer** token (advanced) → `Authorization: Bearer <t>`
 * The browser UI logs in with PAM; the raw bearer path is for API/MCP callers.
 */
const TOKEN_KEY = 'agent_ui_token';
const SCHEME_KEY = 'agent_ui_scheme'; // "Session" | "Bearer"

/** Reactive auth state so the shell can gate on login. */
export const authToken = signal<string>(localStorage.getItem(TOKEN_KEY) || '');

export function setAuth(token: string, scheme: 'Session' | 'Bearer'): void {
  localStorage.setItem(TOKEN_KEY, token);
  localStorage.setItem(SCHEME_KEY, scheme);
  authToken.set(token);
}
export function clearAuth(): void {
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(SCHEME_KEY);
  authToken.set('');
}
export function currentScheme(): 'Session' | 'Bearer' {
  return (localStorage.getItem(SCHEME_KEY) as 'Session' | 'Bearer') || 'Session';
}

/**
 * Rewrites the reused fleet services onto the agent's own single-host API and
 * attaches the stored credential.
 *
 * Fleet services build URLs like `http://host:8123/api/v1/agents/<id>/tools/x`
 * or `.../config-templates`; the standalone agent serves the same modules
 * same-origin at `/api/v1/tools/x` (no `/agents/<id>`). So collapse from
 * `/api/v1/` onward, drop a leading `agents/<id>/`, re-root same-origin. Tool
 * calls also get their raw module Result `{changed,msg,data}` wrapped into the
 * `{agent_id,tool,result}` envelope the components read.
 */
export const agentInterceptor: HttpInterceptorFn = (req, next) => {
  const marker = '/api/v1/';
  const i = req.url.indexOf(marker);
  let out = req;
  let isTool = false;
  let toolName = '';
  if (i >= 0) {
    let path = req.url.slice(i + marker.length).replace(/^agents\/[^/]+\/?/, '');
    isTool = path.startsWith('tools/');
    toolName = isTool ? path.slice('tools/'.length).split('?')[0] : '';
    out = req.clone({ url: marker + path });
  }
  const tok = authToken();
  if (tok && out.url.startsWith('/api/')) {
    out = out.clone({ setHeaders: { Authorization: `${currentScheme()} ${tok}` } });
  }
  // A 401 means the session token is gone/expired (e.g. the agent restarted —
  // PAM sessions are in-memory). Clear it so the shell bounces to the login
  // form instead of showing "failed to load" in every panel.
  const stream = next(out).pipe(tap({
    error: (e) => { if (e && e.status === 401 && authToken()) clearAuth(); },
  }));
  if (!isTool) return stream;
  return stream.pipe(map((ev) => {
    if (ev instanceof HttpResponse && ev.body && typeof ev.body === 'object' && !('result' in (ev.body as object))) {
      return ev.clone({ body: { agent_id: 'self', tool: toolName, result: ev.body } });
    }
    return ev;
  }));
};
