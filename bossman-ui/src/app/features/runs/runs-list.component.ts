import { Component, OnInit, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { DatePipe } from '@angular/common';
import { MatCardModule } from '@angular/material/card';
import { RunService } from '../../core/services/run.service';
import { PlanRun } from '../../core/models/run.model';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { StatusFilterChipsComponent } from '../../shared/components/status-filter-chips/status-filter-chips.component';
import { runStatusBadge } from '../../shared/status.util';

@Component({
  selector: 'app-runs-list',
  standalone: true,
  imports: [RouterLink, DatePipe, MatCardModule, HostStatusBadgeComponent, StatusFilterChipsComponent],
  template: `
    <div class="bm-page">
      <h1>Plan Runs</h1>
      <app-status-filter-chips [selected]="statusFilter()" (statusChange)="onStatusChange($event)" />
      <mat-card>
        <table class="bm-table">
          <thead>
            <tr>
              <th>Plan</th>
              <th>Status</th>
              <th>Dry run</th>
              <th>Requested by</th>
              <th>Started</th>
            </tr>
          </thead>
          <tbody>
            @for (run of runs(); track run.id) {
              <tr [routerLink]="['/runs', run.id]" class="bm-row-link">
                <td>{{ run.plan_name }}</td>
                <td><app-status-badge [status]="statusOf(run)" [label]="run.status" /></td>
                <td>{{ run.dry_run ? 'yes' : 'no' }}</td>
                <td>{{ run.requested_by || '—' }}</td>
                <td>{{ run.started_at | date: 'medium' }}</td>
              </tr>
            } @empty {
              <tr>
                <td colspan="5" class="bm-empty">No plan runs yet.</td>
              </tr>
            }
          </tbody>
        </table>
      </mat-card>
    </div>
  `,
  styles: [
    `
      .bm-page {
        padding: 24px;
        max-width: 1100px;
        margin: 0 auto;
      }
      app-status-filter-chips {
        display: block;
        margin: 12px 0;
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
      }
      .bm-row-link {
        cursor: pointer;
      }
      .bm-row-link:hover {
        background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent);
      }
      .bm-empty {
        opacity: 0.6;
        text-align: center;
      }
    `,
  ],
})
export class RunsListComponent implements OnInit {
  private runService = inject(RunService);
  runs = signal<PlanRun[]>([]);
  statusFilter = signal<string | null>(null);

  ngOnInit(): void {
    this.load();
  }

  onStatusChange(status: string | null): void {
    this.statusFilter.set(status);
    this.load();
  }

  private load(): void {
    this.runService.list({ status: this.statusFilter() ?? undefined, limit: 100 }).subscribe((runs) => this.runs.set(runs));
  }

  statusOf(run: PlanRun) {
    return runStatusBadge(run.status);
  }
}
