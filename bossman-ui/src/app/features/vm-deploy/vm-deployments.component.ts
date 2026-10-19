import { Component, OnDestroy, OnInit, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { MatButtonModule } from '@angular/material/button';
import { MatDialog } from '@angular/material/dialog';
import { MatIconModule } from '@angular/material/icon';
import { DeploymentRow, VmDeployService } from '../../core/services/vm-deploy.service';
import { DeployVmWizardComponent } from './deploy-vm-wizard.component';

/** Hosts Bossman installed (VMs and bare metal) — network installs and golden-image restores with their state, whether the
 *  new host's agent has reported, and the finalization playbook's outcome. "Install a host" opens the wizard; the MCP tool
 *  deploy_vm runs the same backend, so a deployment a model started appears here too. */
@Component({
  selector: 'app-vm-deployments',
  standalone: true,
  imports: [DatePipe, MatButtonModule, MatIconModule],
  template: `
    <div class="vd-page">
      <header>
        <div>
          <h1>Install hosts</h1>
          <p>Install a VM on a hypervisor or a bare-metal machine — Fedora, AlmaLinux, Debian or Ubuntu from the
            distribution's own installer, or a captured golden image — with roles and an optional playbook.</p>
        </div>
        <div class="vd-actions">
          <button mat-stroked-button (click)="reload()" [disabled]="loading()"><mat-icon>refresh</mat-icon> Refresh</button>
          <button mat-flat-button (click)="openWizard()"><mat-icon>add</mat-icon> Install a host</button>
        </div>
      </header>

      @if (error()) { <div class="vd-msg vd-msg--err" role="alert">{{ error() }}</div> }

      @if (!rows().length && !loading() && !error()) {
        <div class="vd-empty">
          <mat-icon>dns</mat-icon>
          <p>No deployments yet. "Install a host" walks through target, operating system, machine, network, roles and playbook,
            and checks everything before it creates anything.</p>
        </div>
      }

      @if (rows().length) {
        <table class="vd-table">
          <thead><tr><th>Host</th><th>System</th><th>Address</th><th>Install</th><th>Agent</th><th>Finalize</th><th>Started</th></tr></thead>
          <tbody>
            @for (r of rows(); track r.hostname + r.created_at) {
              <tr>
                <td><strong>{{ r.hostname }}</strong><div class="vd-dim">VM {{ r.vmid ?? '—' }} · {{ r.mac }}</div></td>
                <td>{{ r.os }}<div class="vd-dim">{{ r.kind === 'install' ? 'network install' : 'golden image' }}</div></td>
                <td>{{ r.address ?? '—' }}</td>
                <td><span class="vd-pill" [attr.data-s]="pill(r.status)" [title]="r.error ?? ''">{{ r.status }}</span>
                  @if (r.error) { <div class="vd-err">{{ r.error }}</div> }</td>
                <td>@if (r.last_seen_at) { <span class="vd-pill" data-s="ok">reported</span>
                      <div class="vd-dim">{{ r.agent_version }} · {{ r.last_seen_at | date: 'short' }}</div> }
                    @else if (pill(r.status) === 'gone') { <span class="vd-dim">—</span> }
                    @else { <span class="vd-pill" data-s="wait">not yet</span> }</td>
                <td>@if (r.finalize; as f) {
                      <span class="vd-pill" [attr.data-s]="pill(f.status)">{{ f.status }}</span>
                      <div class="vd-dim">{{ f.runbook }} ({{ f.apply ? 'apply' : 'check mode' }})</div>
                      @if (f.error) { <div class="vd-err">{{ f.error }}</div> }
                    } @else { <span class="vd-dim">—</span> }</td>
                <td>{{ r.created_at | date: 'short' }}@if (r.finished_at) { <div class="vd-dim">done {{ r.finished_at | date: 'shortTime' }}</div> }</td>
              </tr>
            }
          </tbody>
        </table>
      }
    </div>
  `,
  styles: [`
    .vd-page { padding: 24px; display: flex; flex-direction: column; gap: 16px; }
    header { display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; flex-wrap: wrap; }
    h1 { margin: 0 0 4px; }
    header p { margin: 0; color: var(--mat-sys-on-surface-variant); max-width: 80ch; line-height: 1.5; }
    .vd-actions { display: flex; gap: 8px; }
    .vd-msg { padding: 8px 12px; border-radius: 6px; }
    .vd-msg--err { background: color-mix(in srgb, var(--bm-red, #d0021b) 14%, transparent); }
    .vd-empty { display: flex; flex-direction: column; align-items: center; gap: 8px; padding: 48px 16px; color: var(--mat-sys-on-surface-variant); text-align: center; }
    .vd-empty mat-icon { font-size: 40px; width: 40px; height: 40px; }
    .vd-empty p { max-width: 60ch; }
    .vd-table { width: 100%; border-collapse: collapse; font-size: 13px; }
    .vd-table th { text-align: left; font-weight: 600; color: var(--mat-sys-on-surface-variant); padding: 6px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .vd-table td { padding: 8px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); vertical-align: top; }
    /* Secondary text by a theme token, not opacity: 55 % opacity fell below WCAG 4.5:1 (axe color-contrast). */
    .vd-dim { color: var(--mat-sys-on-surface-variant); font-size: 12px; margin-top: 2px; }
    .vd-err { color: var(--bm-red, #d0021b); font-size: 12px; margin-top: 2px; max-width: 40ch; }
    .vd-pill { display: inline-block; padding: 1px 8px; border-radius: 10px; font-size: 12px; font-weight: 600;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .vd-pill[data-s='ok'] { background: color-mix(in srgb, var(--bm-green, #2e7d32) 22%, transparent); }
    .vd-pill[data-s='run'] { background: color-mix(in srgb, var(--mat-sys-primary) 20%, transparent); }
    /* A deleted VM's row is marked by the dashed pill and an italic host name — never by fading the text, which
       broke the contrast of the whole row. */
    .vd-pill[data-s='gone'] { background: none; border: 1px dashed var(--mat-sys-outline); color: var(--mat-sys-on-surface-variant); }
    tr:has(.vd-pill[data-s='gone']) td strong { font-style: italic; font-weight: 500; }
    .vd-pill[data-s='bad'] { background: color-mix(in srgb, var(--bm-red, #d0021b) 22%, transparent); }
  `],
})
export class VmDeploymentsComponent implements OnInit, OnDestroy {
  private api = inject(VmDeployService);
  private dialog = inject(MatDialog);

  rows = signal<DeploymentRow[]>([]);
  loading = signal(false);
  error = signal('');
  private timer: ReturnType<typeof setInterval> | null = null;

  ngOnInit(): void {
    this.reload();
    this.timer = setInterval(() => { if (this.rows().some((r) => this.pill(r.status) === 'run' || this.pill(r.finalize?.status ?? '') === 'run')) { this.reload(); } }, 15000);
  }

  ngOnDestroy(): void { if (this.timer) { clearInterval(this.timer); } }

  reload(): void {
    this.loading.set(true);
    this.api.deployments().subscribe({
      next: (r) => { this.rows.set(r); this.error.set(''); this.loading.set(false); },
      error: (e) => { this.error.set(e?.error?.detail ?? 'Loading the deployments failed'); this.loading.set(false); },
    });
  }

  /** Status word → colour class; every status lands in one of four named buckets. */
  pill(status: string): 'ok' | 'run' | 'bad' | 'wait' | 'gone' {
    if (['vm_deleted', 'cancelled'].includes(status)) { return 'gone'; }
    if (['done', 'succeeded', 'completed'].includes(status)) { return 'ok'; }
    if (['failed', 'error', 'aborted', 'cancelled'].includes(status)) { return 'bad'; }
    if (['pending', 'waiting', 'armed'].includes(status)) { return 'wait'; }
    return 'run';
  }

  openWizard(): void {
    this.dialog.open(DeployVmWizardComponent, { width: '1040px', maxWidth: '96vw', disableClose: true, autoFocus: false })
      .afterClosed().subscribe(() => this.reload());
  }
}
