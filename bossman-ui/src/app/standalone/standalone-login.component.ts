import { Component, inject, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { FormsModule } from '@angular/forms';
import { setAuth } from './agent-auth';

/**
 * Local login for the standalone-agent console. Username/password go to
 * POST /api/v1/auth/login (the agent verifies them against this host's own
 * accounts) and the returned session_token is stored + sent as
 * `Authorization: Session <token>` on every API call. An advanced field also
 * accepts the agent's static bearer token directly (for API/MCP-style access).
 *
 * GET /api/v1/auth/methods is asked FIRST, before the form is usable, because
 * three different things can make a password login impossible — it is disabled
 * in the agent config, the binary has no PAM and the host no unix_chkpwd, or
 * the user is not in the required group. Each has a different fix, and a form
 * that simply fails names none of them. The endpoint also reports which group
 * is required, so "invalid username or password" can say what it really is.
 */
@Component({
  selector: 'app-standalone-login',
  standalone: true,
  imports: [FormsModule],
  template: `
    <div class="bm-login">
      <form class="bm-card" (ngSubmit)="login()">
        <div class="bm-brand"><strong>YOLO-MANager</strong> <span>standalone agent</span></div>
        @if (passwordLogin() !== false) {
          <label>Username<input name="u" [(ngModel)]="username" autocomplete="username" autofocus [disabled]="passwordLogin() === null" /></label>
          <label>Password<input name="p" type="password" [(ngModel)]="password" autocomplete="current-password" [disabled]="passwordLogin() === null" /></label>
          <button type="submit" [disabled]="passwordLogin() !== true || busy() || !username().trim() || !password()">{{ busy() ? 'Signing in…' : 'Sign in' }}</button>
          @if (group()) { <p class="bm-note">Members of group <code>{{ group() }}</code> may sign in.</p> }
        } @else {
          <p class="bm-err">No password login on this host.</p>
          <p class="bm-note">{{ reason() }}</p>
          <p class="bm-note">Use the agent's API token below, or grant a local account access with
            <code>gpasswd -a &lt;user&gt; {{ group() || 'yoloadmin' }}</code>.</p>
        }
        @if (err()) { <p class="bm-err">{{ err() }}</p> }
        <details class="bm-adv">
          <summary>Advanced: API token</summary>
          <label>Bearer token<input type="password" [(ngModel)]="token" name="t" placeholder="agent token" /></label>
          <button type="button" (click)="useToken()" [disabled]="!token().trim()">Use token</button>
        </details>
      </form>
    </div>
  `,
  styles: [`
    .bm-login { min-height: 100vh; display: flex; align-items: center; justify-content: center; background: #14161a; }
    .bm-card { display: flex; flex-direction: column; gap: 12px; width: 320px; padding: 26px; border-radius: 12px;
      background: #1e2127; color: #e6e6e6; box-shadow: 0 10px 40px rgba(0,0,0,0.4); font-family: system-ui, sans-serif; }
    .bm-brand { font-size: 18px; margin-bottom: 6px; } .bm-brand span { opacity: 0.55; font-size: 12px; }
    label { display: flex; flex-direction: column; gap: 4px; font-size: 12px; opacity: 0.85; }
    input { padding: 8px 10px; border-radius: 6px; border: 1px solid #3a3f47; background: #14161a; color: #eee; }
    button[type=submit] { padding: 9px; border: 0; border-radius: 6px; background: #2e7d32; color: #fff; cursor: pointer; font-weight: 600; }
    button[type=submit]:disabled { opacity: 0.5; cursor: default; }
    .bm-err { color: #ff8a80; font-size: 13px; margin: 0; }
    .bm-note { color: #9aa0a6; font-size: 12px; margin: 0; line-height: 1.45; }
    .bm-note code { color: #cfd3d7; background: #14161a; padding: 1px 4px; border-radius: 3px; }
    .bm-adv { font-size: 12px; opacity: 0.8; } .bm-adv summary { cursor: pointer; }
    .bm-adv label { margin-top: 8px; } .bm-adv button { margin-top: 8px; padding: 6px 12px; border: 1px solid #3a3f47; background: transparent; color: #ccc; border-radius: 6px; cursor: pointer; }
  `],
})
export class StandaloneLoginComponent {
  private http = inject(HttpClient);
  username = signal(''); password = signal(''); token = signal('');
  busy = signal(false); err = signal('');
  /** true = usable, false = this host has none, null = not asked yet (a third state, not a default). */
  passwordLogin = signal<boolean | null>(null);
  reason = signal(''); group = signal('');

  constructor() {
    this.http.get<{ password: boolean; group?: string; password_unavailable_reason?: string }>(
      '/api/v1/auth/methods').subscribe({
      next: (m) => {
        this.passwordLogin.set(!!m.password);
        this.group.set(m.group || '');
        this.reason.set(m.password_unavailable_reason || '');
      },
      // An older agent has no /auth/methods. Offering the form is the right guess there — it is what that
      // version could do — rather than locking out a host because a new endpoint is missing.
      error: () => this.passwordLogin.set(true),
    });
  }

  login(): void {
    this.busy.set(true); this.err.set('');
    this.http.post<{ session_token: string }>('/api/v1/auth/login',
      { username: this.username().trim(), password: this.password() }).subscribe({
      next: (r) => { this.busy.set(false); if (r.session_token) setAuth(r.session_token, 'Session'); else this.err.set('no session token returned'); },
      error: (e) => {
        this.busy.set(false);
        // 401 is deliberately one message: the agent does not tell a caller whether the account exists, the
        // password was wrong, or the group is missing. The group hint above says what to check.
        this.err.set(e?.status === 401
          ? (this.group() ? `Invalid credentials, or not a member of ${this.group()}.` : 'Invalid username or password.')
          : (e?.error?.error || 'Login failed.'));
      },
    });
  }

  useToken(): void { setAuth(this.token().trim(), 'Bearer'); }
}
