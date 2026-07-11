import { Component, inject, input, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService } from '../../../core/services/agent.service';

/** Firewalld section (Cockpit's Firewall): view a zone's active rules
 * (firewall-cmd --list-all via the read-only command tool) and add/remove
 * services or ports through the posix.firewalld module. Writes default to
 * dry-run; needs the firewalld module pushed (Enable management modules). */
@Component({
  selector: 'app-host-firewall',
  standalone: true,
  imports: [MatButtonModule, MatIconModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-mgmt-section">
      <div class="bm-topbar">
        <label class="bm-f">Zone
          <input type="text" [value]="zone()" (input)="zone.set($any($event.target).value)" (keyup.enter)="listRules()" />
        </label>
        <button mat-stroked-button (click)="listRules()" [disabled]="loading()"><mat-icon>refresh</mat-icon> List rules</button>
        <label class="bm-chk"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> Dry run</label>
        <span class="bm-spacer"></span>
        @if (msg()) { <span class="bm-svc-ok">{{ msg() }}</span> }
        @if (err()) { <span class="bm-svc-err">{{ err() }}</span> }
      </div>

      <section class="bm-card">
        <header class="bm-card-head"><h3>Active rules — zone {{ zone() }}</h3></header>
        @if (loading()) {
          <div class="bm-loading"><mat-spinner diameter="24" /></div>
        } @else if (rules()) {
          <pre class="bm-raw">{{ rules() }}</pre>
        } @else {
          <p class="bm-empty">Click “List rules” to read the zone's active configuration.</p>
        }
      </section>

      <div class="bm-grid2">
        <section class="bm-card">
          <header class="bm-card-head"><h3>Service</h3></header>
          <div class="bm-form">
            <input type="text" placeholder="service (e.g. https, ssh, dns)" [value]="svc()" (input)="svc.set($any($event.target).value)" />
            <div class="bm-actions">
              <button mat-stroked-button (click)="setService(true)" [disabled]="busy() || !svc().trim()"><mat-icon>add</mat-icon> Allow</button>
              <button mat-button (click)="setService(false)" [disabled]="busy() || !svc().trim()"><mat-icon>remove</mat-icon> Remove</button>
            </div>
          </div>
        </section>
        <section class="bm-card">
          <header class="bm-card-head"><h3>Port</h3></header>
          <div class="bm-form">
            <input type="text" placeholder="port/proto (e.g. 8080/tcp)" [value]="port()" (input)="port.set($any($event.target).value)" />
            <div class="bm-actions">
              <button mat-stroked-button (click)="setPort(true)" [disabled]="busy() || !port().trim()"><mat-icon>add</mat-icon> Allow</button>
              <button mat-button (click)="setPort(false)" [disabled]="busy() || !port().trim()"><mat-icon>remove</mat-icon> Remove</button>
            </div>
          </div>
        </section>
      </div>
    </div>
  `,
  styles: [`
    .bm-mgmt-section { padding: 4px 0; display: flex; flex-direction: column; gap: 16px; }
    .bm-topbar { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
    .bm-spacer { flex: 1; }
    .bm-f { font-size: 13px; display: flex; align-items: center; gap: 6px; }
    .bm-f input { padding: 6px 9px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; width: 120px; }
    .bm-chk { font-size: 12.5px; opacity: 0.85; display: flex; align-items: center; gap: 5px; }
    .bm-grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
    @media (max-width: 900px) { .bm-grid2 { grid-template-columns: 1fr; } }
    .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; background: var(--mat-sys-surface); }
    .bm-card-head { padding: 10px 14px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-card-head h3 { margin: 0; font-size: 14px; font-weight: 600; }
    .bm-form { padding: 12px 14px; display: flex; flex-direction: column; gap: 10px; }
    .bm-form input { padding: 7px 9px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; }
    .bm-actions { display: flex; gap: 8px; }
    .bm-raw { max-height: 40vh; overflow: auto; background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); padding: 10px 12px; border-radius: 6px; font-size: 12px; margin: 12px 14px; white-space: pre-wrap; }
    .bm-empty { opacity: 0.6; padding: 12px 14px; font-size: 13px; }
    .bm-loading { display: flex; justify-content: center; padding: 20px; }
    .bm-svc-ok { color: var(--bm-green, #2e7d32); font-size: 12px; }
    .bm-svc-err { color: #c62828; font-size: 12px; }
  `],
})
export class HostFirewallComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  zone = signal('public');
  dryRun = signal(true);
  rules = signal<string>('');
  svc = signal('');
  port = signal('');
  loading = signal(false);
  loaded = signal(false);
  busy = signal(false);
  msg = signal<string | null>(null);
  err = signal<string | null>(null);

  loadOnce(): void {
    if (this.loaded()) return;
    this.loaded.set(true);
    this.listRules();
  }

  listRules(): void {
    this.loading.set(true);
    this.err.set(null);
    this.agentService.callTool(this.agentId(), 'command', { argv: ['firewall-cmd', '--list-all', '--zone=' + this.zone().trim()] }).subscribe({
      next: (res) => {
        this.loading.set(false);
        const data = (res.result as { data?: { stdout?: string; stderr?: string } })?.data;
        this.rules.set(data?.stdout || data?.stderr || '(no output)');
      },
      error: (e) => { this.loading.set(false); this.err.set(e?.error?.detail ?? 'could not read firewall (is firewalld installed + module pushed?)'); },
    });
  }

  setService(allow: boolean): void {
    this.fw({ service: this.svc().trim() }, allow, `${allow ? 'allow' : 'remove'} service ${this.svc().trim()}`);
  }

  setPort(allow: boolean): void {
    this.fw({ port: this.port().trim() }, allow, `${allow ? 'allow' : 'remove'} port ${this.port().trim()}`);
  }

  private fw(target: Record<string, unknown>, allow: boolean, label: string): void {
    this.busy.set(true);
    this.msg.set(null);
    this.err.set(null);
    this.agentService
      .callTool(this.agentId(), 'posix.firewalld', {
        ...target, zone: this.zone().trim(), state: allow ? 'enabled' : 'disabled',
        permanent: true, immediate: true, dry_run: this.dryRun(),
      })
      .subscribe({
        next: (res) => {
          this.busy.set(false);
          const r = res.result as { msg?: string } | undefined;
          this.msg.set(`${label}: ${r?.msg ?? 'ok'}${this.dryRun() ? ' (dry-run)' : ''}`);
          if (!this.dryRun()) this.listRules();
        },
        error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail ?? 'firewall action failed'); },
      });
  }
}
