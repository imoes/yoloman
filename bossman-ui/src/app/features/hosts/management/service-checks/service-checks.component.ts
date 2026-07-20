import { Component, computed, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatDialog } from '@angular/material/dialog';
import { forkJoin } from 'rxjs';
import { CheckService } from '../../../../core/services/check.service';
import { AgentService } from '../../../../core/services/agent.service';
import { CheckCatalogEntry, EffectiveCheck } from '../../../../core/models/check.model';
import { AddServiceCheckDialogComponent } from './add-service-check-dialog.component';

/** MMC snap-in: active service checks (HTTP/TCP/DNS/…) on a host — configure
 * them as easily as Roles & Features. Lists the checks assigned to THIS host,
 * "Add a service check" opens the catalog→param-form→assign dialog. */
@Component({
  selector: 'app-service-checks',
  standalone: true,
  imports: [FormsModule, MatButtonModule, MatIconModule],
  template: `
    <div class="bm-sc-head">
      <div>
        <h3>Service checks</h3>
        <p class="bm-dim">Monitor a URL, port, certificate or DNS record from this host — pick a check, fill the form, done.</p>
      </div>
      <button mat-flat-button color="primary" (click)="add()"><mat-icon>add</mat-icon> Add a service check</button>
    </div>

    @if (!ready()) {
      <p class="bm-dim">Loading…</p>
    } @else if (!assigned().length) {
      <p class="bm-dim">No service checks on this host yet. Use <strong>Add a service check</strong> to monitor an endpoint.</p>
    } @else {
      <table class="bm-sc-tbl">
        <thead><tr><th>Service</th><th>Check</th><th>Target</th><th>Scope</th><th></th></tr></thead>
        <tbody>
          @for (c of assigned(); track c.assignment_id + c.check_name) {
            <tr>
              <td>{{ serviceName(c) }}</td>
              <td class="bm-mono">{{ label(c.check_name) }}</td>
              <td class="bm-mono bm-target">{{ target(c) }}</td>
              <td><span class="bm-scope">{{ c.source_scope }}</span></td>
              <td class="bm-sc-act">
                @if (c.source_scope === 'host') {
                  <button mat-stroked-button (click)="edit(c)"><mat-icon>edit</mat-icon> Edit</button>
                  <button mat-stroked-button (click)="remove(c)"><mat-icon>delete</mat-icon> Remove</button>
                } @else {
                  <span class="bm-dim">from {{ c.source_scope }}</span>
                }
              </td>
            </tr>
          }
        </tbody>
      </table>
    }
  `,
  styles: [`
    .bm-sc-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; margin-bottom: 12px; }
    .bm-sc-head h3 { margin: 0; }
    .bm-dim { opacity: 0.62; margin: 2px 0 0; font-size: 13px; }
    .bm-sc-tbl { width: 100%; border-collapse: collapse; font-size: 13px; }
    .bm-sc-tbl th { text-align: left; font-size: 12px; opacity: 0.6; padding: 6px 10px; }
    .bm-sc-tbl td { padding: 8px 10px; border-top: 1px solid var(--mat-sys-outline-variant); vertical-align: middle; }
    .bm-mono { font-family: ui-monospace, monospace; font-size: 12px; }
    .bm-target { opacity: 0.8; max-width: 320px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bm-scope { font-size: 11px; padding: 1px 9px; border-radius: 10px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
  `],
})
export class ServiceChecksComponent {
  private checkService = inject(CheckService);
  private agentService = inject(AgentService);
  private dialog = inject(MatDialog);
  agentId = input.required<string>();

  private effective = signal<EffectiveCheck[] | null>(null);
  private catalog = signal<Record<string, CheckCatalogEntry>>({});
  private hostName = signal('');

  ready = computed(() => this.effective() !== null && Object.keys(this.catalog()).length > 0);

  // Only the active service checks (category "Service checks"), not the
  // hundreds of agent/SNMP checks — those live under Devices / auto-discovery.
  assigned = computed(() =>
    (this.effective() ?? []).filter((c) => this.catalog()[c.check_name]?.category === 'Service checks'));

  ngOnInit(): void { this.reload(); }

  private reload(): void {
    forkJoin({
      eff: this.checkService.effectiveHostChecks(this.agentId()),
      cat: this.checkService.listChecks(),
      agent: this.agentService.get(this.agentId()),
    }).subscribe(({ eff, cat, agent }) => {
      this.effective.set(eff.checks);
      this.catalog.set(Object.fromEntries((cat.checks || []).map((c) => [c.name, c])));
      this.hostName.set(agent.name);
    });
  }

  label(name: string): string {
    const c = this.catalog()[name];
    const d = (c?.short_description || '').replace(/%s/g, '').replace(/\s+/g, ' ').trim();
    return d || name;
  }
  serviceName(c: EffectiveCheck): string {
    return String((c.parameters?.['service_name'] as string) || this.label(c.check_name));
  }
  target(c: EffectiveCheck): string {
    const p = c.parameters || {};
    return String(p['url'] || p['host'] || p['name'] || (p['port'] ? `:${p['port']}` : '') || '');
  }

  add(): void {
    this.dialog.open(AddServiceCheckDialogComponent, {
      data: { agentId: this.agentId(), hostName: this.hostName() || this.agentId() },
      width: 'min(760px, 94vw)', maxWidth: '94vw',
    }).afterClosed().subscribe((created) => { if (created) this.reload(); });
  }

  /** Reconfigure a host-scoped check: reopen the param form pre-filled and
   * PATCH the assignment (no delete+recreate). */
  edit(c: EffectiveCheck): void {
    this.dialog.open(AddServiceCheckDialogComponent, {
      data: {
        agentId: this.agentId(),
        hostName: this.hostName() || this.agentId(),
        edit: { assignmentId: c.assignment_id, checkName: c.check_name, parameters: { ...(c.parameters || {}) } },
      },
      width: 'min(760px, 94vw)', maxWidth: '94vw',
    }).afterClosed().subscribe((saved) => { if (saved) this.reload(); });
  }

  remove(c: EffectiveCheck): void {
    this.checkService.deleteAssignment(c.assignment_id).subscribe(() => this.reload());
  }
}
