import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { DatePipe } from '@angular/common';
import { MatCardModule } from '@angular/material/card';
import { MonitoringService } from '../../core/services/monitoring.service';
import { AgentService } from '../../core/services/agent.service';
import { DialogService } from '../../shared/dialogs/dialog.service';
import { FleetHost } from '../../core/models/monitoring.model';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { PerfOMeterComponent } from '../../shared/components/perf-o-meter/perf-o-meter.component';
import { serviceStateBadge } from '../../shared/status.util';

interface HostRow extends FleetHost {
  indent: boolean;
}

/**
 * The real host-overview table (see docs/plan.md's monitoring-cockpit
 * ergänzung Block F3) — CheckMK/Zabbix's own "Latest data" table: CPU
 * load, RAM, and disk usage at a glance via Perf-O-Meter bars, plus a
 * CheckMK-style state rollup, sourced from GET /api/v1/fleet/hosts (one
 * call, real values — not the old Name/Address/Mode/Status table with no
 * metrics at all). Satellites discovered behind a proxy are grouped
 * directly under their parent, indented, instead of being invisible.
 */
@Component({
  selector: 'app-hosts-list',
  standalone: true,
  imports: [RouterLink, DatePipe, MatCardModule, HostStatusBadgeComponent, PerfOMeterComponent],
  template: `
    <div class="bm-page">
      <h1>Hosts</h1>
      <mat-card>
        <table class="bm-table">
          <thead>
            <tr>
              <th>Name</th>
              <th>State</th>
              <th>CPU load</th>
              <th>Memory</th>
              <th>Disk (max)</th>
              <th>Services</th>
              <th>Last seen</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            @for (host of rows(); track host.id) {
              <tr [routerLink]="['/hosts', host.id]" class="bm-row-link">
                <td [class.bm-indent]="host.indent">
                  @if (host.indent) {
                    <span class="bm-tree-glyph">↳</span>
                  }
                  {{ host.name }}
                </td>
                <td><app-status-badge [status]="badgeOf(host)" [label]="host.state_rollup" /></td>
                <td>{{ host.cpu_load !== null ? host.cpu_load.toFixed(2) : '—' }}</td>
                <td><app-perf-o-meter [value]="host.mem_used_pct" [warn]="80" [crit]="90" /></td>
                <td><app-perf-o-meter [value]="host.disk_used_pct_max" [warn]="80" [crit]="90" /></td>
                <td class="bm-service-counts">
                  @if (host.service_counts['CRIT']) {
                    <span class="bm-count bm-count--crit">{{ host.service_counts['CRIT'] }} CRIT</span>
                  }
                  @if (host.service_counts['WARN']) {
                    <span class="bm-count bm-count--warn">{{ host.service_counts['WARN'] }} WARN</span>
                  }
                  @if (host.service_counts['OK']) {
                    <span class="bm-count bm-count--ok">{{ host.service_counts['OK'] }} OK</span>
                  }
                </td>
                <td>{{ host.last_seen_at ? (host.last_seen_at | date: 'medium') : 'never' }}</td>
                <td class="bm-actions-cell">
                  <button
                    type="button"
                    class="bm-icon-btn"
                    title="Update agent — push a new .deb; the agent installs it and restarts"
                    [disabled]="updating() === host.id"
                    (click)="onUpdateClick(host, fileInput, $event)"
                  >
                    {{ updating() === host.id ? '⏳' : '⬆' }}
                  </button>
                  <button
                    type="button"
                    class="bm-delete-btn"
                    title="Delete host"
                    [disabled]="deleting() === host.id"
                    (click)="deleteHost(host, $event)"
                  >
                    🗑
                  </button>
                </td>
              </tr>
            } @empty {
              <tr>
                <td colspan="8" class="bm-empty">
                  No hosts enrolled yet. Go to
                  <a routerLink="/settings" (click)="$event.stopPropagation()">Settings</a> for the enrollment command.
                </td>
              </tr>
            }
          </tbody>
        </table>
      </mat-card>
      <!-- Hidden picker shared by every row's Update button (Block N-deploy):
           the clicked row is remembered in pendingUpdateId. -->
      <input #fileInput type="file" accept=".deb" hidden (change)="onFileChosen($event)" />
    </div>
  `,
  styles: [
    `
      .bm-page {
        padding: 24px;
        max-width: 1200px;
        margin: 0 auto;
      }
      .bm-table {
        width: 100%;
        border-collapse: collapse;
      }
      .bm-table th {
        text-align: left;
        font-size: 12px;
        opacity: 0.7;
        padding: 10px 12px;
      }
      .bm-table td {
        padding: 10px 12px;
        border-top: 1px solid var(--mat-sys-outline-variant);
        vertical-align: middle;
      }
      .bm-row-link {
        cursor: pointer;
      }
      .bm-row-link:hover {
        background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent);
      }
      .bm-indent {
        padding-left: 28px;
        opacity: 0.85;
      }
      .bm-tree-glyph {
        opacity: 0.5;
        margin-right: 4px;
      }
      .bm-service-counts {
        display: flex;
        gap: 8px;
        white-space: nowrap;
      }
      .bm-count {
        font-size: 12px;
        font-weight: 600;
      }
      .bm-count--ok {
        color: var(--bm-green);
      }
      .bm-count--warn {
        color: var(--bm-gold);
      }
      .bm-count--crit {
        color: var(--bm-red);
      }
      .bm-empty {
        opacity: 0.6;
        text-align: center;
      }
      .bm-actions-cell {
        text-align: right;
        white-space: nowrap;
      }
      .bm-delete-btn,
      .bm-icon-btn {
        background: none;
        border: none;
        cursor: pointer;
        font-size: 15px;
        opacity: 0.55;
        padding: 4px 6px;
        border-radius: 4px;
        line-height: 1;
      }
      .bm-icon-btn:hover {
        opacity: 1;
        background: color-mix(in srgb, var(--bm-green) 18%, transparent);
      }
      .bm-icon-btn:disabled {
        opacity: 0.4;
        cursor: default;
      }
      .bm-delete-btn:hover {
        opacity: 1;
        background: color-mix(in srgb, var(--bm-red) 18%, transparent);
      }
      .bm-delete-btn:disabled {
        opacity: 0.3;
        cursor: default;
      }
    `,
  ],
})
export class HostsListComponent implements OnInit {
  private monitoringService = inject(MonitoringService);
  private agentService = inject(AgentService);
  private dialog = inject(DialogService);
  hosts = signal<FleetHost[]>([]);
  /** The id currently being deleted, so its button disables (prevents a
   * double-submit); null when idle. */
  deleting = signal<string | null>(null);
  /** The id currently being updated (agent .deb push in flight). */
  updating = signal<string | null>(null);
  /** The host whose Update button was clicked, awaiting the file pick. */
  private pendingUpdateId: string | null = null;

  /** Top-level hosts first (in name order), each immediately followed by
   * its own satellites (also name-ordered) — a simple two-level tree
   * flattened for a plain table, no recursive component needed since
   * this project's proxy nesting is deliberately single-hop (v1 scope). */
  rows = computed<HostRow[]>(() => {
    const all = this.hosts();
    const byParent = new Map<string, FleetHost[]>();
    for (const h of all) {
      if (h.parent_agent_id) {
        const list = byParent.get(h.parent_agent_id) ?? [];
        list.push(h);
        byParent.set(h.parent_agent_id, list);
      }
    }
    const top = all.filter((h) => !h.parent_agent_id).sort((a, b) => a.name.localeCompare(b.name));
    const out: HostRow[] = [];
    for (const h of top) {
      out.push({ ...h, indent: false });
      const children = (byParent.get(h.id) ?? []).sort((a, b) => a.name.localeCompare(b.name));
      for (const c of children) {
        out.push({ ...c, indent: true });
      }
    }
    return out;
  });

  ngOnInit(): void {
    this.reload();
  }

  private reload(): void {
    this.monitoringService.fleetHosts().subscribe((hosts) => this.hosts.set(hosts));
  }

  badgeOf(host: FleetHost) {
    return serviceStateBadge(host.state_rollup);
  }

  /** Update button: remember the host, then open the shared file picker.
   * stopPropagation so the row's routerLink doesn't fire. */
  onUpdateClick(host: FleetHost, input: HTMLInputElement, event: Event): void {
    event.stopPropagation();
    if (this.updating()) return;
    this.pendingUpdateId = host.id;
    input.value = ''; // allow re-picking the same file
    input.click();
  }

  /** A .deb was chosen — push it to the pending host's self-update endpoint. */
  onFileChosen(event: Event): void {
    const input = event.target as HTMLInputElement;
    const file = input.files?.[0];
    const id = this.pendingUpdateId;
    this.pendingUpdateId = null;
    if (!file || !id) return;
    this.updating.set(id);
    this.agentService.update(id, file).subscribe({
      next: () => {
        this.updating.set(null);
        this.dialog.notify('Agent update pushed — the host is installing it and will restart onto the new version.');
      },
      error: (e) => {
        this.updating.set(null);
        this.dialog.notify(e?.error?.detail ?? 'agent update failed', 'error');
      },
    });
  }

  /** Delete a host after a confirm. stopPropagation keeps the row's
   * routerLink from firing (a click on the button would otherwise navigate
   * into the host we're removing). */
  async deleteHost(host: FleetHost, event: Event): Promise<void> {
    event.stopPropagation();
    if (this.deleting()) return;
    if (!(await this.dialog.confirm({ title: 'Delete host', message: `Delete host "${host.name}" and all its data? This cannot be undone.`, confirmText: 'Delete', danger: true }))) return;
    this.deleting.set(host.id);
    this.agentService.delete(host.id).subscribe({
      next: () => {
        this.deleting.set(null);
        this.reload();
      },
      error: () => this.deleting.set(null),
    });
  }
}
