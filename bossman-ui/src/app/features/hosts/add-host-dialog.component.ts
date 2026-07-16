import { Component, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { EnrollService } from '../../core/services/enroll.service';
import { EnrollInfo } from '../../core/models/enroll.model';

/** "Add host" — the enrollment entry point, surfaced from the Hosts page
 * instead of being buried in Settings. Two paths, mirroring Settings:
 *  1. copy a one-line register command to run on the host (zero-touch since
 *     `register` now self-configures);
 *  2. if server-driven deploy is configured, paste hostnames and let Bossman
 *     SSH in, install the agent, and enroll them — nothing to run on the host.
 * Resolves with the number of hosts deployed so the list can refresh. */
@Component({
  selector: 'app-add-host-dialog',
  standalone: true,
  imports: [FormsModule, MatDialogModule, MatButtonModule, MatIconModule],
  template: `
    <h2 mat-dialog-title>Add a host</h2>
    <mat-dialog-content>
      @if (info(); as i) {
        <section class="bm-method">
          <h3><mat-icon>terminal</mat-icon> Run a command on the host</h3>
          <p class="bm-dim">Run this on the server — the agent self-configures, enrolls, and appears here.</p>
          @if (i.register_command) {
            <div class="bm-cmd-row">
              <code>{{ i.register_command }}</code>
              <button mat-icon-button (click)="copy(i.register_command)" title="Copy"><mat-icon>{{ copied() ? 'check' : 'content_copy' }}</mat-icon></button>
            </div>
          } @else {
            <p class="bm-dim">Set <code>BOSSMAN_PUBLIC_URL</code> so the exact command can be shown.</p>
          }
        </section>

        @if (i.deploy_configured) {
          <section class="bm-method">
            <h3><mat-icon>cloud_upload</mat-icon> Let Bossman install it (SSH)</h3>
            <p class="bm-dim">One host per line (IP or DNS). Bossman SSHes in with its operator identity, installs the agent, and enrolls each.</p>
            <textarea [(ngModel)]="hosts" rows="4" placeholder="host1.example.com&#10;host2.example.com" [disabled]="deploying()"></textarea>
            <div class="bm-deploy-actions">
              <button mat-flat-button color="primary" [disabled]="deploying() || !hosts.trim()" (click)="deploy()">
                {{ deploying() ? 'Deploying…' : 'Deploy & enroll' }}
              </button>
            </div>
            @for (r of results(); track r.host) {
              <p class="bm-result" [class.bm-ok]="r.ok" [class.bm-fail]="!r.ok">
                <mat-icon>{{ r.ok ? 'check_circle' : 'error' }}</mat-icon> {{ r.host }} — {{ r.msg }}
              </p>
            }
          </section>
        }
      } @else {
        <p class="bm-dim">Loading enrollment options…</p>
      }
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="ref.close(deployedCount())">Close</button>
    </mat-dialog-actions>
  `,
  styles: [`
    mat-dialog-content { min-width: 480px; }
    .bm-method { margin-bottom: 18px; }
    .bm-method h3 { display: flex; align-items: center; gap: 8px; margin: 0 0 4px; font-size: 15px; }
    .bm-method h3 mat-icon { font-size: 19px; width: 19px; height: 19px; opacity: 0.8; }
    .bm-dim { opacity: 0.7; font-size: 13px; margin: 4px 0 8px; }
    .bm-cmd-row { display: flex; align-items: center; gap: 6px; }
    .bm-cmd-row code { flex: 1; padding: 8px 10px; background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); border-radius: 6px; font-size: 12.5px; overflow-x: auto; white-space: nowrap; }
    textarea { width: 100%; box-sizing: border-box; padding: 8px 10px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; font-family: ui-monospace, monospace; font-size: 13px; resize: vertical; }
    .bm-deploy-actions { margin-top: 8px; }
    .bm-result { display: flex; align-items: center; gap: 6px; font-size: 13px; margin: 4px 0; }
    .bm-result mat-icon { font-size: 17px; width: 17px; height: 17px; }
    .bm-ok { color: #2e7d32; } .bm-fail { color: var(--bm-red); }
  `],
})
export class AddHostDialogComponent {
  private enroll = inject(EnrollService);
  info = signal<EnrollInfo | null>(null);
  hosts = '';
  copied = signal(false);
  deploying = signal(false);
  results = signal<{ host: string; ok: boolean; msg: string }[]>([]);
  deployedCount = signal(0);

  constructor(public ref: MatDialogRef<AddHostDialogComponent, number>) {
    this.enroll.info().subscribe({ next: (i) => this.info.set(i), error: () => this.info.set({ configured: false, enroll_url: null, register_command: null, deploy_configured: false }) });
  }

  copy(cmd: string): void {
    navigator.clipboard?.writeText(cmd);
    this.copied.set(true);
    setTimeout(() => this.copied.set(false), 2000);
  }

  deploy(): void {
    const hosts = this.hosts.split('\n').map((h) => h.trim()).filter(Boolean);
    if (!hosts.length) return;
    this.deploying.set(true);
    this.results.set([]);
    let pending = hosts.length;
    for (const host of hosts) {
      this.enroll.deploy(host).subscribe({
        next: (r) => { this.results.update((x) => [...x, { host, ok: true, msg: `enrolled as ${r.name}` }]); this.deployedCount.update((n) => n + 1); if (--pending === 0) this.deploying.set(false); },
        error: (e) => { this.results.update((x) => [...x, { host, ok: false, msg: e?.error?.detail ?? 'failed' }]); if (--pending === 0) this.deploying.set(false); },
      });
    }
  }
}
