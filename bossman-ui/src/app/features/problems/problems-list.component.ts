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
import { MatDialog } from '@angular/material/dialog';
import { MonitoringService } from '../../core/services/monitoring.service';
import { ServiceState } from '../../core/models/monitoring.model';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { StatusFilterChipsComponent } from '../../shared/components/status-filter-chips/status-filter-chips.component';
import { AcknowledgeDialogComponent, AcknowledgeDialogResult } from '../../shared/components/acknowledge-dialog/acknowledge-dialog.component';
import { DowntimeDialogComponent, DowntimeDialogResult } from '../../shared/components/downtime-dialog/downtime-dialog.component';
import { serviceStateBadge } from '../../shared/status.util';

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
    HostStatusBadgeComponent,
    StatusFilterChipsComponent,
  ],
  template: `
    <div class="bm-page">
      <h1>Problems</h1>

      <div class="bm-filters">
        <app-status-filter-chips [selected]="stateFilter()" [statuses]="states" (statusChange)="onStateChange($event)" />
        <mat-form-field appearance="outline" class="bm-host-filter">
          <mat-label>Host</mat-label>
          <input matInput [(ngModel)]="hostFilter" (ngModelChange)="onHostFilterChange($event)" placeholder="Filter by host name" />
        </mat-form-field>
        <mat-slide-toggle [checked]="showAcknowledged()" (change)="onShowAcknowledgedChange($event.checked)">
          Show acknowledged
        </mat-slide-toggle>
      </div>

      <mat-card>
        @if (problems().length) {
          <table class="bm-table">
            <thead>
              <tr>
                <th>Host</th>
                <th>Service</th>
                <th>State</th>
                <th>Since</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              @for (p of problems(); track p.id) {
                <tr>
                  <td><a [routerLink]="['/hosts', p.agent_id]">{{ p.agent_name }}</a></td>
                  <td>{{ p.name }}</td>
                  <td><app-status-badge [status]="badgeOf(p)" [label]="p.state" /></td>
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
      .bm-tag {
        font-size: 12px;
        opacity: 0.75;
        margin-right: 8px;
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

  states = ['WARN', 'CRIT', 'UNKNOWN'];
  problems = signal<ServiceState[]>([]);
  loaded = signal(false);
  stateFilter = signal<string | null>(null);
  hostFilter = '';
  showAcknowledged = signal(false);

  ngOnInit(): void {
    this.reload();
  }

  reload(): void {
    this.monitoringService
      .problems({
        state: this.stateFilter() ?? undefined,
        host: this.hostFilter || undefined,
        acknowledged: this.showAcknowledged() ? undefined : false,
      })
      .subscribe((problems) => {
        this.problems.set(problems);
        this.loaded.set(true);
      });
  }

  onStateChange(state: string | null): void {
    this.stateFilter.set(state);
    this.reload();
  }

  onHostFilterChange(_value: string): void {
    this.reload();
  }

  onShowAcknowledgedChange(value: boolean): void {
    this.showAcknowledged.set(value);
    this.reload();
  }

  badgeOf(p: ServiceState) {
    return serviceStateBadge(p.state);
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
