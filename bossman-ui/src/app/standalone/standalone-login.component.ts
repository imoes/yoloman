import { Component, inject, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { FormsModule } from '@angular/forms';
import { setAuth } from './agent-auth';

/**
 * PAM login for the standalone-agent console. Username/password go to
 * POST /api/v1/auth/login (the agent authenticates them against local OS
 * accounts via PAM) and the returned session_token is stored + sent as
 * `Authorization: Session <token>` on every API call. An advanced field also
 * accepts the agent's static bearer token directly (for API/MCP-style access).
 */
@Component({
  selector: 'app-standalone-login',
  standalone: true,
  imports: [FormsModule],
  template: `
    <div class="bm-login">
      <form class="bm-card" (ngSubmit)="login()">
        <div class="bm-brand"><strong>YOLO-MANager</strong> <span>standalone agent</span></div>
        <label>Username<input name="u" [(ngModel)]="username" autocomplete="username" autofocus /></label>
        <label>Password<input name="p" type="password" [(ngModel)]="password" autocomplete="current-password" /></label>
        <button type="submit" [disabled]="busy() || !username().trim() || !password()">{{ busy() ? 'Signing in…' : 'Sign in (PAM)' }}</button>
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
    .bm-adv { font-size: 12px; opacity: 0.8; } .bm-adv summary { cursor: pointer; }
    .bm-adv label { margin-top: 8px; } .bm-adv button { margin-top: 8px; padding: 6px 12px; border: 1px solid #3a3f47; background: transparent; color: #ccc; border-radius: 6px; cursor: pointer; }
  `],
})
export class StandaloneLoginComponent {
  private http = inject(HttpClient);
  username = signal(''); password = signal(''); token = signal('');
  busy = signal(false); err = signal('');

  login(): void {
    this.busy.set(true); this.err.set('');
    this.http.post<{ session_token: string }>('/api/v1/auth/login',
      { username: this.username().trim(), password: this.password() }).subscribe({
      next: (r) => { this.busy.set(false); if (r.session_token) setAuth(r.session_token, 'Session'); else this.err.set('no session token returned'); },
      error: (e) => { this.busy.set(false); this.err.set(e?.status === 401 ? 'Invalid username or password.' : (e?.error?.error || 'Login failed.')); },
    });
  }

  useToken(): void { setAuth(this.token().trim(), 'Bearer'); }
}
