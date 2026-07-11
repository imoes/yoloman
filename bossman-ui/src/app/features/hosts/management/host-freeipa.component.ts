import { Component, inject, input, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService } from '../../../core/services/agent.service';

/** FreeIPA section: show the host's IPA enrollment status, install the
 * freeipa-client package, and enroll the host (ipa-client-install). Enrolling
 * configures SSSD so IPA accounts can authenticate — including logging in at
 * the web console. Install/enroll default to dry-run; the enrollment password
 * is sent once over mTLS and never stored. */
@Component({
  selector: 'app-host-freeipa',
  standalone: true,
  imports: [MatButtonModule, MatIconModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-mgmt-section">
      <div class="bm-topbar">
        <label class="bm-chk"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> Dry run (preview only)</label>
        <span class="bm-spacer"></span>
        @if (msg()) { <span class="bm-svc-ok">{{ msg() }}</span> }
        @if (err()) { <span class="bm-svc-err">{{ err() }}</span> }
      </div>

      <!-- Enrollment status -->
      <section class="bm-card">
        <header class="bm-card-head">
          <h3>Enrollment status</h3>
          @if (enrolled() === true) { <span class="bm-pill bm-up">Enrolled</span> }
          @else if (enrolled() === false) { <span class="bm-pill bm-down">Not enrolled</span> }
          <span class="bm-spacer"></span>
          <button mat-stroked-button (click)="checkStatus()" [disabled]="checking()"><mat-icon>refresh</mat-icon> Check</button>
        </header>
        @if (checking()) { <div class="bm-loading"><mat-spinner diameter="22" /></div> }
        @else if (statusText()) { <pre class="bm-raw">{{ statusText() }}</pre> }
        @else { <p class="bm-empty">Click “Check” to read <code>/etc/ipa/default.conf</code>.</p> }
      </section>

      <!-- Install client -->
      <section class="bm-card">
        <header class="bm-card-head"><h3>FreeIPA client</h3></header>
        <div class="bm-form">
          <p class="bm-hint">Installs the <code>freeipa-client</code> / <code>ipa-client</code> package (apt or dnf, auto-detected).</p>
          <div><button mat-stroked-button (click)="installClient()" [disabled]="busy()"><mat-icon>download</mat-icon> Install freeipa-client</button></div>
        </div>
      </section>

      <!-- Enroll -->
      <section class="bm-card">
        <header class="bm-card-head"><h3>Enroll host</h3></header>
        <div class="bm-form">
          <div class="bm-frow"><label>IPA domain</label><input type="text" placeholder="ipa.example.com" [value]="domain()" (input)="domain.set($any($event.target).value)" /></div>
          <div class="bm-frow"><label>IPA server</label><input type="text" placeholder="ipa1.example.com (optional, autodiscover)" [value]="server()" (input)="server.set($any($event.target).value)" /></div>
          <div class="bm-frow"><label>Principal</label><input type="text" placeholder="admin" [value]="principal()" (input)="principal.set($any($event.target).value)" /></div>
          <div class="bm-frow"><label>Password</label><input type="password" placeholder="enrollment / principal password" [value]="password()" (input)="password.set($any($event.target).value)" /></div>
          <div class="bm-frow"><label><input type="checkbox" [checked]="mkhomedir()" (change)="mkhomedir.set($any($event.target).checked)" /> Create home dirs on login (mkhomedir)</label></div>
          <div><button mat-raised-button color="primary" (click)="enroll()" [disabled]="busy() || !domain().trim() || !principal().trim() || !password()"><mat-icon>verified_user</mat-icon> Enroll</button></div>
          <p class="bm-hint">Enrolling configures SSSD so IPA accounts can log in (incl. the web console). Password is used once, not stored.</p>
        </div>
      </section>
    </div>
  `,
  styles: [`
    .bm-mgmt-section { padding: 4px 0; display: flex; flex-direction: column; gap: 16px; }
    .bm-topbar { display: flex; align-items: center; gap: 12px; }
    .bm-spacer { flex: 1; }
    .bm-chk { font-size: 12.5px; opacity: 0.85; display: flex; align-items: center; gap: 5px; }
    .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; background: var(--mat-sys-surface); }
    .bm-card-head { display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-card-head h3 { margin: 0; font-size: 14px; font-weight: 600; }
    .bm-pill { font-size: 11.5px; padding: 2px 10px; border-radius: 999px; font-weight: 500; }
    .bm-pill.bm-up { background: color-mix(in srgb, var(--bm-green, #2e7d32) 20%, transparent); color: var(--bm-green, #2e7d32); }
    .bm-pill.bm-down { background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); opacity: 0.8; }
    .bm-form { padding: 12px 14px; display: flex; flex-direction: column; gap: 10px; }
    .bm-frow { display: grid; grid-template-columns: 170px 1fr; align-items: center; gap: 10px; max-width: 560px; }
    .bm-frow label { font-size: 13px; opacity: 0.85; }
    .bm-frow input[type=text], .bm-frow input[type=password] { padding: 7px 9px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; }
    .bm-hint { opacity: 0.6; font-size: 12px; margin: 0; }
    .bm-raw { max-height: 30vh; overflow: auto; background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); padding: 10px 12px; border-radius: 6px; font-size: 12px; margin: 12px 14px; white-space: pre-wrap; }
    .bm-empty { opacity: 0.6; padding: 12px 14px; font-size: 13px; }
    .bm-loading { display: flex; justify-content: center; padding: 18px; }
    .bm-svc-ok { color: var(--bm-green, #2e7d32); font-size: 12px; }
    .bm-svc-err { color: #c62828; font-size: 12px; }
  `],
})
export class HostFreeipaComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  dryRun = signal(true);
  checking = signal(false);
  loaded = signal(false);
  enrolled = signal<boolean | null>(null);
  statusText = signal<string>('');
  domain = signal('');
  server = signal('');
  principal = signal('admin');
  password = signal('');
  mkhomedir = signal(true);
  busy = signal(false);
  msg = signal<string | null>(null);
  err = signal<string | null>(null);

  loadOnce(): void {
    if (this.loaded()) return;
    this.loaded.set(true);
    this.checkStatus();
  }

  checkStatus(): void {
    this.checking.set(true);
    this.err.set(null);
    this.agentService.callTool(this.agentId(), 'command', { argv: ['cat', '/etc/ipa/default.conf'] }).subscribe({
      next: (res) => {
        this.checking.set(false);
        const data = (res.result as { data?: { stdout?: string; rc?: number } })?.data;
        const out = data?.stdout || '';
        this.enrolled.set(!!out.trim() && (data?.rc ?? 1) === 0);
        this.statusText.set(out.trim() || 'not enrolled (/etc/ipa/default.conf absent)');
      },
      error: () => { this.checking.set(false); this.enrolled.set(false); this.statusText.set('not enrolled (/etc/ipa/default.conf absent)'); },
    });
  }

  installClient(): void {
    const cmd = 'if command -v apt-get >/dev/null; then apt-get install -y freeipa-client; else dnf install -y ipa-client freeipa-client || yum install -y ipa-client; fi';
    this.shell(cmd, 'install freeipa-client');
  }

  enroll(): void {
    const parts = ['ipa-client-install', '--unattended', '--mkhomedir', '--domain=' + shq(this.domain().trim()),
      '--principal=' + shq(this.principal().trim()), '--password=' + shq(this.password())];
    if (this.server().trim()) parts.push('--server=' + shq(this.server().trim()));
    if (!this.mkhomedir()) parts.splice(parts.indexOf('--mkhomedir'), 1);
    this.shell(parts.join(' '), `enroll ${this.domain().trim()}`);
  }

  private shell(cmd: string, label: string): void {
    this.busy.set(true);
    this.msg.set(null);
    this.err.set(null);
    this.agentService.callTool(this.agentId(), 'shell', { cmd, dry_run: this.dryRun() }).subscribe({
      next: (res) => {
        this.busy.set(false);
        const data = (res.result as { data?: { rc?: number; stdout?: string; stderr?: string; msg?: string } })?.data;
        if (this.dryRun()) { this.msg.set(`${label}: would run (dry-run)`); return; }
        const rc = data?.rc ?? 0;
        if (rc === 0) { this.msg.set(`${label}: ok`); this.checkStatus(); }
        else this.err.set(`${label} failed (rc ${rc}): ${(data?.stderr || data?.stdout || '').slice(-200)}`);
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail ?? `${label} failed`); },
    });
  }
}

/** Minimal single-quote shell escaping for values embedded in the command. */
function shq(v: string): string {
  return "'" + v.replace(/'/g, "'\\''") + "'";
}
