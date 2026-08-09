import { Component, OnInit, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { RouterLink } from '@angular/router';
import { FormsModule } from '@angular/forms';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatDialog } from '@angular/material/dialog';
import { MonitoringService } from '../../core/services/monitoring.service';
import { ServiceState } from '../../core/models/monitoring.model';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { FilterBarComponent, FilterDef, FilterValues } from '../../shared/components/filter-bar/filter-bar.component';
import { AcknowledgeDialogComponent, AcknowledgeDialogResult } from '../../shared/components/acknowledge-dialog/acknowledge-dialog.component';
import { DowntimeDialogComponent, DowntimeDialogResult } from '../../shared/components/downtime-dialog/downtime-dialog.component';
import { serviceStateBadge } from '../../shared/status.util';
import { formatMetricValue, thresholdContext } from '../../shared/format.util';

/**
 * The full "unbehandelte Probleme" view (see docs/plan.md's monitoring
 * Block E4) — every real monitoring system's primary triage surface.
 * Filterable by state/host/acknowledged, with per-row acknowledge and
 * schedule-downtime actions (the same two mutations the MCP tools
 * acknowledge_problem/schedule_downtime expose to an AI operator).
 */
@Component({
  selector: 'app-problems-list',
  standalone: true,
  imports: [
    RouterLink,
    DatePipe,
    FormsModule,
    MatCardModule,
    MatButtonModule,
    MatIconModule,
    MatSlideToggleModule,
    MatFormFieldModule,
    MatInputModule,
    MatCheckboxModule,
    HostStatusBadgeComponent,
    FilterBarComponent,
  ],
  template: `
    <div class="bm-page">
      <h1>Problems</h1>

      <app-filter-bar class="bm-filters" [filters]="filterDefs" [values]="fvals()" (valuesChange)="onFilters($event)" />

      @if (selectedCount()) {
        <div class="bm-bulk-bar">
          <span class="bm-bulk-count">{{ selectedCount() }} selected</span>
          <button mat-raised-button color="primary" (click)="bulkAcknowledge()">
            <mat-icon>done_all</mat-icon> Acknowledge selected
          </button>
          <button mat-button (click)="clearSelection()">Clear</button>
        </div>
      }

      <mat-card>
        @if (problems().length) {
          <table class="bm-table">
            <thead>
              <tr>
                <th class="bm-cb">
                  <mat-checkbox [checked]="allSelected()" [indeterminate]="someSelected()"
                                (change)="toggleAll($event.checked)" title="Select all shown" />
                </th>
                <th>Host</th>
                <th>Service</th>
                <th>State</th>
                <th>Detail</th>
                <th>Since</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              @for (p of problems(); track p.id) {
                <tr [class.bm-row-sel]="isSelected(p.id)">
                  <td class="bm-cb">
                    <mat-checkbox [checked]="isSelected(p.id)" (change)="toggle(p.id)" />
                  </td>
                  <td><a [routerLink]="['/hosts', p.agent_id]">{{ p.agent_name }}</a></td>
                  <td>{{ p.name }}</td>
                  <td><app-status-badge [status]="badgeOf(p)" [label]="p.state" /></td>
                  <td class="bm-detail" [title]="p.output">
                    <div class="bm-detail-value">{{ svcValue(p) }}</div>
                    @if (thresholdOf(p); as t) {
                      <div class="bm-detail-thresh">{{ t }}</div>
                    } @else {
                      <div class="bm-detail-thresh">{{ p.output }}</div>
                    }
                  </td>
                  <td>{{ p.last_state_change | date: 'medium' }}</td>
                  <td>
                    @if (p.in_downtime) {
                      <span class="bm-tag">in downtime</span>
                    }
                    @if (p.acknowledged) {
                      <span class="bm-tag" [title]="p.ack_comment || ''">acked by {{ p.ack_by }}</span>
                    }
                  </td>
                  <td class="bm-actions">
                    @if (!p.acknowledged) {
                      <button mat-button (click)="acknowledge(p)">Acknowledge</button>
                    } @else {
                      <button mat-button (click)="unacknowledge(p)">Unacknowledge</button>
                    }
                    <button mat-button (click)="scheduleDowntime(p)">Downtime</button>
                  </td>
                </tr>
              }
            </tbody>
          </table>
        } @else if (loaded()) {
          <p class="bm-empty">No open problems — the fleet is healthy.</p>
        }
      </mat-card>
    </div>
  `,
  styles: [
    `
      .bm-page {
        padding: 24px;
        max-width: 1200px;
        margin: 0 auto;
      }
      .bm-filters {
        display: flex;
        align-items: center;
        gap: 20px;
        margin-bottom: 16px;
        flex-wrap: wrap;
      }
      .bm-host-filter {
        width: 220px;
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
        padding: 8px 12px;
        border-top: 1px solid var(--mat-sys-outline-variant);
      }
      .bm-actions {
        white-space: nowrap;
        text-align: right;
      }
      .bm-cb {
        width: 40px;
        padding-left: 12px;
      }
      .bm-row-sel {
        background: color-mix(in srgb, var(--mat-sys-primary) 8%, transparent);
      }
      .bm-bulk-bar {
        display: flex;
        align-items: center;
        gap: 12px;
        margin-bottom: 12px;
        padding: 8px 14px;
        border-radius: 8px;
        background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent);
        border: 1px solid var(--mat-sys-primary);
      }
      .bm-bulk-count {
        font-weight: 600;
      }
      .bm-tag {
        font-size: 12px;
        opacity: 0.75;
        margin-right: 8px;
      }
      .bm-detail-value {
        font-variant-numeric: tabular-nums;
        font-weight: 600;
      }
      .bm-detail-thresh {
        font-size: 12px;
        opacity: 0.6;
        font-variant-numeric: tabular-nums;
      }
      .bm-empty {
        opacity: 0.6;
        padding: 24px;
        text-align: center;
      }
    `,
  ],
})
export class ProblemsListComponent implements OnInit {
  private monitoringService = inject(MonitoringService);
  private dialog = inject(MatDialog);

  filterDefs: FilterDef[] = [
    { ident: 'state', label: 'State', kind: 'chips', options: [
      { value: 'WARN', label: 'WARN' }, { value: 'CRIT', label: 'CRIT' }, { value: 'UNKNOWN', label: 'UNKNOWN' },
    ] },
    { ident: 'host', label: 'Host', kind: 'text', placeholder: 'Filter by host name' },
    { ident: 'show_acknowledged', label: 'Show acknowledged', kind: 'checkbox' },
  ];
  fvals = signal<FilterValues>({});
  problems = signal<ServiceState[]>([]);
  loaded = signal(false);
  /** Multi-select for bulk acknowledge — set of selected service (problem) ids. */
  selected = signal<Set<string>>(new Set());

  ngOnInit(): void {
    this.reload();
  }

  reload(): void {
    const v = this.fvals();
    this.monitoringService
      .problems({
        state: (v['state'] as string) || undefined,
        host: (v['host'] as string) || undefined,
        acknowledged: v['show_acknowledged'] === true ? undefined : false,
      })
      .subscribe((problems) => {
        this.problems.set(problems);
        this.loaded.set(true);
        // Drop selections that are no longer in the (re)filtered list.
        const ids = new Set(problems.map((p) => p.id));
        const kept = new Set([...this.selected()].filter((id) => ids.has(id)));
        this.selected.set(kept);
      });
  }

  // ---- multi-select ----
  selectedCount(): number {
    return this.selected().size;
  }
  isSelected(id: string): boolean {
    return this.selected().has(id);
  }
  allSelected(): boolean {
    const rows = this.problems();
    return rows.length > 0 && rows.every((p) => this.selected().has(p.id));
  }
  someSelected(): boolean {
    return this.selectedCount() > 0 && !this.allSelected();
  }
  toggle(id: string): void {
    const next = new Set(this.selected());
    next.has(id) ? next.delete(id) : next.add(id);
    this.selected.set(next);
  }
  toggleAll(checked: boolean): void {
    this.selected.set(checked ? new Set(this.problems().map((p) => p.id)) : new Set());
  }
  clearSelection(): void {
    this.selected.set(new Set());
  }

  bulkAcknowledge(): void {
    const ids = [...this.selected()];
    if (!ids.length) return;
    const ref = this.dialog.open(AcknowledgeDialogComponent, {
      width: '420px',
      data: { serviceName: `${ids.length} problems`, hostName: 'multiple hosts' },
    });
    ref.afterClosed().subscribe((result: AcknowledgeDialogResult | undefined) => {
      if (!result) return;
      this.monitoringService.bulkAcknowledge(ids, result.comment, result.expireAfterMinutes).subscribe(() => {
        this.clearSelection();
        this.reload();
      });
    });
  }

  onFilters(values: FilterValues): void {
    this.fvals.set(values);
    this.reload();
  }

  badgeOf(p: ServiceState) {
    return serviceStateBadge(p.state);
  }

  /** F-17: the tripped value, humane-formatted (mapped label wins if present). */
  svcValue(p: ServiceState): string {
    if (p.mapped_value) return p.mapped_value;
    return formatMetricValue(p.value, p.metric, p.name);
  }

  /** F-17: "warn ≥ 80 %, crit ≥ 90 %" — what the value is graded against. */
  thresholdOf(p: ServiceState): string {
    return thresholdContext(p);
  }

  acknowledge(p: ServiceState): void {
    const ref = this.dialog.open(AcknowledgeDialogComponent, {
      width: '420px',
      data: { serviceName: p.name, hostName: p.agent_name },
    });
    ref.afterClosed().subscribe((result: AcknowledgeDialogResult | undefined) => {
      if (!result) return;
      this.monitoringService.acknowledge(p.id, result.comment, result.expireAfterMinutes).subscribe(() => this.reload());
    });
  }

  unacknowledge(p: ServiceState): void {
    this.monitoringService.unacknowledge(p.id).subscribe(() => this.reload());
  }

  scheduleDowntime(p: ServiceState): void {
    const ref = this.dialog.open(DowntimeDialogComponent, {
      width: '420px',
      data: { hostName: p.agent_name, serviceName: p.name },
    });
    ref.afterClosed().subscribe((result: DowntimeDialogResult | undefined) => {
      if (!result) return;
      const now = new Date();
      const endsAt = new Date(now.getTime() + result.minutes * 60_000);
      this.monitoringService
        .createDowntime({
          agent_id: p.agent_id,
          service_name: p.name,
          starts_at: now.toISOString(),
          ends_at: endsAt.toISOString(),
          comment: result.comment,
        })
        .subscribe(() => this.reload());
    });
  }
}
