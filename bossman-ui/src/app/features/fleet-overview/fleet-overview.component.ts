import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { RouterLink } from '@angular/router';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatDialog } from '@angular/material/dialog';
import { AgentService } from '../../core/services/agent.service';
import { RunService } from '../../core/services/run.service';
import { MonitoringService } from '../../core/services/monitoring.service';
import { Agent } from '../../core/models/agent.model';
import { PlanRun } from '../../core/models/run.model';
import { FleetSummary, ServiceState } from '../../core/models/monitoring.model';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { AcknowledgeDialogComponent } from '../../shared/components/acknowledge-dialog/acknowledge-dialog.component';
import { agentHealthStatus, runStatusBadge, serviceStateBadge } from '../../shared/status.util';

/**
 * The fleet-wide summary landing page (see docs/plan.md's Bossman plan,
 * section C.1, reworked in monitoring Block E4 to lead with CheckMK's own
 * "unbehandelte Probleme" landing principle instead of the earlier
 * host-enrollment-only tiles). The plan called for Gridstack-based
 * draggable widgets; this v1 deliberately ships a fixed CSS-grid layout
 * of the same information instead — Bossman's REST API has no per-user
 * layout-preference storage yet, so a drag-customizable grid would have
 * nothing to persist to, and static cards cover the actual goal ("see
 * fleet health at a glance") without that extra machinery.
 */
@Component({
  selector: 'app-fleet-overview',
  standalone: true,
  imports: [RouterLink, DatePipe, MatCardModule, MatButtonModule, MatIconModule, HostStatusBadgeComponent],
  template: `
    <div class="bm-page">
      <h1>Fleet Overview</h1>

      <div class="bm-summary-row">
        <mat-card class="bm-summary-card">
          <mat-card-content>
            <div class="bm-summary-value">{{ summary()?.hosts_total ?? agents().length }}</div>
            <div class="bm-summary-label">Hosts</div>
          </mat-card-content>
        </mat-card>
        <mat-card class="bm-summary-card">
          <mat-card-content>
            <div class="bm-summary-value bm-ok">{{ servicesByState().OK }}</div>
            <div class="bm-summary-label">Services OK</div>
          </mat-card-content>
        </mat-card>
        <mat-card class="bm-summary-card">
          <mat-card-content>
            <div class="bm-summary-value bm-warn">{{ servicesByState().WARN }}</div>
            <div class="bm-summary-label">Warning</div>
          </mat-card-content>
        </mat-card>
        <mat-card class="bm-summary-card">
          <mat-card-content>
            <div class="bm-summary-value bm-crit">{{ servicesByState().CRIT }}</div>
            <div class="bm-summary-label">Critical</div>
          </mat-card-content>
        </mat-card>
        <mat-card class="bm-summary-card">
          <mat-card-content>
            <div class="bm-summary-value bm-unknown">{{ servicesByState().UNKNOWN }}</div>
            <div class="bm-summary-label">Unknown</div>
          </mat-card-content>
        </mat-card>
        <mat-card class="bm-summary-card bm-summary-card--problems" routerLink="/problems">
          <mat-card-content>
            <div class="bm-summary-value bm-crit">{{ summary()?.open_problems ?? 0 }}</div>
            <div class="bm-summary-label">Open problems</div>
          </mat-card-content>
        </mat-card>
      </div>

      <mat-card class="bm-panel bm-problems-panel">
        <mat-card-header>
          <mat-card-title>Unhandled problems</mat-card-title>
        </mat-card-header>
        <mat-card-content>
          @if (problems().length) {
            <table class="bm-table">
              <thead>
                <tr>
                  <th>Host</th>
                  <th>Service</th>
                  <th>State</th>
                  <th>Since</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                @for (p of problems(); track p.id) {
                  <tr>
                    <td><a [routerLink]="['/hosts', p.agent_id]">{{ p.agent_name }}</a></td>
                    <td>{{ p.name }}</td>
                    <td><app-status-badge [status]="badgeOf(p)" [label]="p.state" /></td>
                    <td>{{ p.last_state_change | date: 'short' }}</td>
                    <td class="bm-actions">
                      <button mat-button (click)="acknowledge(p)">Acknowledge</button>
                    </td>
                  </tr>
                }
              </tbody>
            </table>
          } @else {
            <p class="bm-empty">No open problems — the fleet is healthy.</p>
          }
        </mat-card-content>
        <mat-card-actions>
          <button mat-button routerLink="/problems">View all problems</button>
        </mat-card-actions>
      </mat-card>

      <div class="bm-grid">
        <mat-card class="bm-panel">
          <mat-card-header>
            <mat-card-title>Recent Plan Runs</mat-card-title>
          </mat-card-header>
          <mat-card-content>
            @if (recentRuns().length) {
              <table class="bm-table">
                <thead>
                  <tr>
                    <th>Plan</th>
                    <th>Status</th>
                    <th>Started</th>
                  </tr>
                </thead>
                <tbody>
                  @for (run of recentRuns(); track run.id) {
                    <tr [routerLink]="['/runs', run.id]" class="bm-row-link">
                      <td>{{ run.plan_name }}</td>
                      <td><app-status-badge [status]="statusOf(run)" [label]="run.status" /></td>
                      <td>{{ run.started_at | date: 'medium' }}</td>
                    </tr>
                  }
                </tbody>
              </table>
            } @else {
              <p class="bm-empty">No plan runs yet.</p>
            }
          </mat-card-content>
          <mat-card-actions>
            <button mat-button routerLink="/runs">View all runs</button>
          </mat-card-actions>
        </mat-card>

        <mat-card class="bm-panel">
          <mat-card-header>
            <mat-card-title>Quick actions</mat-card-title>
          </mat-card-header>
          <mat-card-content>
            <p>Take a plan and run it against a host.</p>
          </mat-card-content>
          <mat-card-actions>
            <button mat-raised-button color="primary" routerLink="/plans">
              <mat-icon>play_arrow</mat-icon>
              Run a plan
            </button>
            <button mat-button routerLink="/topology">
              <mat-icon>account_tree</mat-icon>
              View topology
            </button>
          </mat-card-actions>
        </mat-card>
      </div>
    </div>
  `,
  styles: [
    `
      .bm-page {
        padding: 24px;
        max-width: 1100px;
        margin: 0 auto;
      }
      .bm-summary-row {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(130px, 1fr));
        gap: 12px;
        margin-bottom: 20px;
      }
      .bm-summary-card mat-card-content {
        text-align: center;
      }
      .bm-summary-card--problems {
        cursor: pointer;
      }
      .bm-summary-value {
        font-size: 32px;
        font-weight: 600;
        line-height: 1.1;
      }
      .bm-summary-label {
        font-size: 12px;
        text-transform: uppercase;
        letter-spacing: 0.04em;
        opacity: 0.7;
      }
      .bm-ok {
        color: var(--bm-green);
      }
      .bm-warn {
        color: var(--bm-gold);
      }
      .bm-crit {
        color: var(--bm-red);
      }
      .bm-unknown {
        color: var(--bm-unknown);
      }
      .bm-problems-panel {
        margin-bottom: 16px;
      }
      .bm-grid {
        display: grid;
        grid-template-columns: 2fr 1fr;
        gap: 16px;
      }
      .bm-table {
        width: 100%;
        border-collapse: collapse;
      }
      .bm-table th {
        text-align: left;
        font-size: 12px;
        opacity: 0.7;
        padding: 6px 8px;
      }
      .bm-table td {
        padding: 8px;
        border-top: 1px solid var(--mat-sys-outline-variant);
      }
      .bm-actions {
        text-align: right;
      }
      .bm-row-link {
        cursor: pointer;
      }
      .bm-row-link:hover {
        background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent);
      }
      .bm-empty {
        opacity: 0.6;
      }
      @media (max-width: 800px) {
        .bm-grid {
          grid-template-columns: 1fr;
        }
      }
    `,
  ],
})
export class FleetOverviewComponent implements OnInit {
  private agentService = inject(AgentService);
  private runService = inject(RunService);
  private monitoringService = inject(MonitoringService);
  private dialog = inject(MatDialog);

  agents = signal<Agent[]>([]);
  recentRuns = signal<PlanRun[]>([]);
  summary = signal<FleetSummary | null>(null);
  problems = signal<ServiceState[]>([]);

  servicesByState = computed(() => {
    const defaults = { OK: 0, WARN: 0, CRIT: 0, UNKNOWN: 0 };
    return { ...defaults, ...(this.summary()?.services_by_state ?? {}) };
  });

  ngOnInit(): void {
    this.agentService.list().subscribe((agents) => this.agents.set(agents));
    this.runService.list({ limit: 10 }).subscribe((runs) => this.recentRuns.set(runs));
    this.monitoringService.fleetSummary().subscribe((summary) => this.summary.set(summary));
    this.reloadProblems();
  }

  private reloadProblems(): void {
    this.monitoringService.problems({ acknowledged: false }).subscribe((problems) => this.problems.set(problems.slice(0, 10)));
  }

  statusOf(run: PlanRun) {
    return runStatusBadge(run.status);
  }

  badgeOf(p: ServiceState) {
    return serviceStateBadge(p.state);
  }

  acknowledge(p: ServiceState): void {
    const ref = this.dialog.open(AcknowledgeDialogComponent, {
      width: '420px',
      data: { serviceName: p.name, hostName: p.agent_name },
    });
    ref.afterClosed().subscribe((comment: string | undefined) => {
      if (comment === undefined) return;
      this.monitoringService.acknowledge(p.id, comment).subscribe(() => this.reloadProblems());
    });
  }
}
