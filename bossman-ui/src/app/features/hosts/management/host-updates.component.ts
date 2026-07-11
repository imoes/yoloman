import { Component, computed, inject, input, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService } from '../../../core/services/agent.service';
import { SecurityService } from '../../../core/services/security.service';
import { UpdatesResponse } from '../../../core/models/agent.model';

/** Cockpit "Software updates" mapped onto the baked yoloman.package_updates
 * module (apt / dnf / yum, auto-detected): a summary card with Apply-all /
 * Apply-security actions (dry-run by default) and a table of pending updates
 * with a security badge. A reboot-required banner mirrors Cockpit's. */
@Component({
  selector: 'app-host-updates',
  standalone: true,
  imports: [MatButtonModule, MatIconModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-mgmt-section">
      @if (loading()) {
        <div class="bm-mgmt-loading"><mat-spinner diameter="28" /></div>
      } @else if (loadErr()) {
        <p class="bm-svc-err">{{ loadErr() }}</p>
      } @else if (data(); as u) {
        @if (u.reboot_required) {
          <div class="bm-reboot"><mat-icon>restart_alt</mat-icon> A reboot is required to finish applying updates.</div>
        }

        <!-- Summary -->
        <section class="bm-card">
          <header class="bm-card-head">
            <h3>Software updates</h3>
            @if (u.manager !== 'unknown') { <span class="bm-prov"><mat-icon class="bm-prov-ic">inventory_2</mat-icon>{{ u.manager }}</span> }
            <span class="bm-spacer"></span>
            <button mat-stroked-button (click)="reload()" [disabled]="loading() || busy()"><mat-icon>refresh</mat-icon> Check for updates</button>
          </header>
          <div class="bm-summary">
            @if (u.count === 0) {
              <p class="bm-uptodate"><mat-icon>check_circle</mat-icon> System is up to date.</p>
            } @else {
              <p class="bm-count">
                <strong>{{ u.count }}</strong> update{{ u.count === 1 ? '' : 's' }} available
                @if (u.security_count > 0) { <span class="bm-sec-badge">{{ u.security_count }} security</span> }
              </p>
              <div class="bm-actions">
                <label class="bm-chk"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> Dry run (preview only)</label>
                <span class="bm-spacer"></span>
                <button mat-stroked-button (click)="applyInTerminal()" [disabled]="busy()" title="Run the upgrade interactively in a terminal — see output and answer dpkg config prompts">
                  <mat-icon>terminal</mat-icon> Apply in terminal
                </button>
                @if (u.security_count !== 0) {
                  <button mat-stroked-button (click)="apply(true)" [disabled]="busy()">Apply security updates</button>
                }
                <button mat-raised-button color="primary" (click)="apply(false)" [disabled]="busy()">
                  @if (busy()) { <mat-spinner diameter="16" /> } @else { Apply all updates }
                </button>
              </div>
              <p class="bm-hint">Non-interactive apply forces the existing config on prompts. Use <strong>Apply in terminal</strong> to see output and choose keep-config / maintainer's version yourself.</p>
            }
            @if (msg()) { <p class="bm-svc-ok">{{ msg() }}</p> }
            @if (err()) { <p class="bm-svc-err">{{ err() }}</p> }
          </div>
        </section>

        <!-- Security: CVEs closed by the pending upgrades (Block 4-D) -->
        <section class="bm-card">
          <header class="bm-card-head">
            <h3>CVEs fixed by these updates</h3>
            @if (cveCount() >= 0) { <span class="bm-sec-badge">{{ cveCount() }}</span> }
            <span class="bm-spacer"></span>
            <button mat-stroked-button (click)="correlateCves()" [disabled]="cveBusy()">
              @if (cveBusy()) { <mat-spinner diameter="16" /> } @else { <mat-icon>security</mat-icon> Correlate CVEs }
            </button>
          </header>
          <div class="bm-summary">
            @if (cveErr()) { <p class="bm-svc-err">{{ cveErr() }}</p> }
            @if (cveCount() === 0) { <p class="bm-uptodate"><mat-icon>check_circle</mat-icon> No known CVEs closed by the pending updates.</p> }
            @if (cves().length) {
              <table class="bm-ct">
                <thead><tr><th>CVE</th><th>Package</th><th>Installed</th><th>Fixed in</th><th>Severity</th></tr></thead>
                <tbody>
                  @for (c of cves(); track c.cve + c.package) {
                    <tr>
                      <td class="bm-mono">{{ c.cve }}</td>
                      <td class="bm-mono">{{ c.package }}</td>
                      <td class="bm-mono">{{ c.current_version || '—' }}</td>
                      <td class="bm-mono">{{ c.fixed_version || '—' }}</td>
                      <td>@if (c.severity) { <span class="bm-sec-badge">{{ c.severity }}</span> }</td>
                    </tr>
                  }
                </tbody>
              </table>
            }
          </div>
        </section>

        <!-- Pending updates -->
        @if (u.count > 0) {
          <section class="bm-card">
            <header class="bm-card-head"><h3>Available packages</h3></header>
            <table class="bm-ct">
              <thead><tr><th>Package</th><th>Current</th><th>Available</th><th></th></tr></thead>
              <tbody>
                @for (p of u.updates; track p.name) {
                  <tr>
                    <td class="bm-dev">{{ p.name }}</td>
                    <td class="bm-mono">{{ p.current || '—' }}</td>
                    <td class="bm-mono">{{ p.candidate || '—' }}</td>
                    <td class="bm-right">@if (p.security) { <span class="bm-sec-badge">security</span> }</td>
                  </tr>
                }
              </tbody>
            </table>
          </section>
        }
      }
    </div>
  `,
  styles: [
    `
      .bm-mgmt-section { padding: 4px 0; display: flex; flex-direction: column; gap: 16px; }
      .bm-mgmt-loading { display: flex; justify-content: center; padding: 24px; }
      .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; background: var(--mat-sys-surface); }
      .bm-card-head { display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
      .bm-card-head h3 { margin: 0; font-size: 14px; font-weight: 600; }
      .bm-spacer { flex: 1; }
      .bm-summary { padding: 12px 14px; display: flex; flex-direction: column; gap: 10px; }
      .bm-count { margin: 0; font-size: 14px; }
      .bm-uptodate { display: flex; align-items: center; gap: 8px; margin: 0; font-size: 14px; color: var(--bm-green, #2e7d32); }
      .bm-uptodate mat-icon { color: var(--bm-green, #2e7d32); }
      .bm-actions { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
      .bm-chk { font-size: 12.5px; opacity: 0.85; display: flex; align-items: center; gap: 5px; }
      .bm-reboot { display: flex; align-items: center; gap: 8px; padding: 10px 14px; border-radius: 8px; font-size: 13px; background: color-mix(in srgb, #ed6c02 18%, transparent); color: #e65100; }
      .bm-sec-badge { display: inline-block; font-size: 11px; padding: 1px 8px; border-radius: 999px; font-weight: 600; background: color-mix(in srgb, #c62828 16%, transparent); color: #c62828; }
      .bm-ct { width: 100%; border-collapse: collapse; font-size: 13px; }
      .bm-ct th { text-align: left; font-weight: 500; opacity: 0.6; padding: 6px 14px; font-size: 12px; }
      .bm-ct td { padding: 8px 14px; border-top: 1px solid var(--mat-sys-outline-variant); vertical-align: middle; }
      .bm-right { text-align: right; }
      .bm-dev { font-family: monospace; font-weight: 600; }
      .bm-mono { font-family: monospace; }
      .bm-prov { display: inline-flex; align-items: center; gap: 4px; font-size: 11.5px; padding: 2px 10px; border-radius: 999px; font-weight: 500; background: color-mix(in srgb, var(--mat-sys-primary) 14%, transparent); color: var(--mat-sys-primary); }
      .bm-prov-ic { font-size: 14px; width: 14px; height: 14px; }
      .bm-svc-ok { color: var(--bm-green, #2e7d32); font-size: 12px; margin: 0; }
      .bm-svc-err { color: #c62828; font-size: 12px; margin: 0; }
      .bm-hint { font-size: 12px; opacity: 0.6; margin: 2px 0 0; }
    `,
  ],
})
export class HostUpdatesComponent {
  private agentService = inject(AgentService);
  private security = inject(SecurityService);

  agentId = input.required<string>();

  data = signal<UpdatesResponse | null>(null);
  loading = signal(false);
  loaded = signal(false);
  loadErr = signal<string | null>(null);
  busy = signal(false);
  msg = signal<string | null>(null);
  err = signal<string | null>(null);
  dryRun = signal(true);

  cves = signal<{ cve: string; package: string; current_version: string; fixed_version: string; severity: string }[]>([]);
  cveCount = signal(-1);
  cveBusy = signal(false);
  cveErr = signal<string | null>(null);

  /** Open a stand-alone terminal window running the interactive upgrade, so
   * the user sees output and answers dpkg config prompts themselves. */
  applyInTerminal(): void {
    const id = this.agentId();
    window.open(
      `${location.origin}/console/${id}?run=updates`,
      `bm-upd-${id}-${Date.now()}`,
      'width=1000,height=640,menubar=no,toolbar=no,location=no',
    );
  }

  /** Correlate this host's pending updates to the CVEs they fix (Block 4-D). */
  correlateCves(): void {
    this.cveBusy.set(true);
    this.cveErr.set(null);
    this.security.hostCves(this.agentId()).subscribe({
      next: (r) => { this.cveBusy.set(false); this.cves.set(r.cves); this.cveCount.set(r.count); },
      error: (e) => { this.cveBusy.set(false); this.cveErr.set(e?.error?.detail ?? 'correlation failed (is the CVE feed refreshed?)'); },
    });
  }

  loadOnce(): void {
    if (this.loaded() || this.loading()) return;
    this.reload();
  }

  reload(): void {
    this.loading.set(true);
    this.loadErr.set(null);
    this.msg.set(null);
    this.err.set(null);
    this.agentService.updates(this.agentId()).subscribe({
      next: (res) => { this.data.set(res); this.loading.set(false); this.loaded.set(true); },
      error: (e) => { this.loading.set(false); this.loaded.set(true); this.loadErr.set(e?.error?.detail ?? 'failed to load updates'); },
    });
  }

  apply(securityOnly: boolean): void {
    this.busy.set(true);
    this.msg.set(null);
    this.err.set(null);
    this.agentService.applyUpdates(this.agentId(), { security_only: securityOnly, dry_run: this.dryRun() }).subscribe({
      next: (res) => {
        this.busy.set(false);
        const r = res.result as { msg?: string } | undefined;
        this.msg.set(`${r?.msg ?? 'ok'}${this.dryRun() ? ' (dry-run)' : ''}`);
        if (!this.dryRun()) this.reload();
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail ?? 'apply failed'); },
    });
  }
}
