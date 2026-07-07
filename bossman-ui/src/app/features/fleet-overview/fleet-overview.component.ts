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
import { DashboardGridComponent } from './dashboard-grid.component';

/**
 * The fleet-wide summary landing page (see docs/plan.md's Bossman plan,
 * section C.1, reworked in monitoring Block E4 to lead with CheckMK's own
 * "unbehandelte Probleme" landing principle instead of the earlier
 * host-enrollment-only tiles). The top summary cards + problems panel stay
 * fixed (always-relevant fleet-health KPIs, not something an operator
 * would rearrange); Block F5 adds a real GridStack widget dashboard below
 * them (`<app-dashboard-grid>`) for the part an operator actually wants to
 * customize — see docs/plan.md's Block F5.
 */
@Component({
  selector: 'app-fleet-overview',
  standalone: true,
  imports: [RouterLink, DatePipe, MatCardModule, MatButtonModule, MatIconModule, HostStatusBadgeComponent, DashboardGridComponent],
  template: `
    <div class="bm-page">
      <h1>Fleet Overview</h1>

      <!-- CheckMK-style statistics panels (Block H3): Host statistics +
           Service statistics side by side, each a colored-count table —
           the same at-a-glance layout as CheckMK's problems dashboard,
           in the Rastafari palette. -->
      <div class="bm-stats-row">
        <mat-card class="bm-stats-card">
          <div class="bm-stats-title">Host statistics</div>
          <div class="bm-stats-body">
            <div class="bm-stats-total">
              <div class="bm-stats-total-value">{{ summary()?.hosts_total ?? agents().length }}</div>
              <div class="bm-stats-total-label">Total</div>
            </div>
            <table class="bm-stats-table">
              @for (row of hostStats(); track row.label) {
                <tr>
                  <td><span class="bm-sq" [style.background]="row.color"></span></td>
                  <td>{{ row.label }}</td>
                  <td class="bm-stats-count">{{ row.count }}</td>
                </tr>
              }
            </table>
          </div>
        </mat-card>

        <mat-card class="bm-stats-card">
          <div class="bm-stats-title">Service statistics</div>
          <div class="bm-stats-body">
            <div class="bm-stats-total">
              <div class="bm-stats-total-value">{{ servicesTotal() }}</div>
              <div class="bm-stats-total-label">Total</div>
            </div>
            <table class="bm-stats-table">
              <tr>
                <td><span class="bm-sq bm-sq--ok"></span></td>
                <td>OK</td>
                <td class="bm-stats-count">{{ servicesByState().OK }}</td>
              </tr>
              <tr>
                <td><span class="bm-sq bm-sq--warn"></span></td>
                <td>Warning</td>
                <td class="bm-stats-count">{{ servicesByState().WARN }}</td>
              </tr>
              <tr>
                <td><span class="bm-sq bm-sq--crit"></span></td>
                <td>Critical</td>
                <td class="bm-stats-count">{{ servicesByState().CRIT }}</td>
              </tr>
              <tr>
                <td><span class="bm-sq bm-sq--unknown"></span></td>
                <td>Unknown</td>
                <td class="bm-stats-count">{{ servicesByState().UNKNOWN }}</td>
              </tr>
            </table>
          </div>
        </mat-card>

        <mat-card class="bm-stats-card bm-stats-card--problems" routerLink="/problems">
          <div class="bm-stats-title">Open problems</div>
          <div class="bm-stats-problems">
            <div class="bm-stats-total-value" [class.bm-crit]="(summary()?.open_problems ?? 0) > 0" [class.bm-ok]="(summary()?.open_problems ?? 0) === 0">
              {{ summary()?.open_problems ?? 0 }}
            </div>
            <div class="bm-stats-total-label">
              {{ (summary()?.open_problems ?? 0) === 0 ? 'everything irie' : 'unhandled' }}
            </div>
          </div>
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

      <app-dashboard-grid class="bm-dashboard-section" />

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
      .bm-stats-row {
        display: grid;
        grid-template-columns: 1fr 1fr 0.8fr;
        gap: 12px;
        margin-bottom: 20px;
      }
      .bm-stats-card {
        padding: 14px 16px;
        border-top: 3px solid transparent;
        border-image: linear-gradient(90deg, var(--bm-red) 0%, var(--bm-gold) 50%, var(--bm-green) 100%) 1;
      }
      .bm-stats-card--problems {
        cursor: pointer;
        text-align: center;
      }
      .bm-stats-title {
        font-size: 12px;
        text-transform: uppercase;
        letter-spacing: 0.05em;
        opacity: 0.7;
        margin-bottom: 10px;
      }
      .bm-stats-body {
        display: flex;
        align-items: center;
        gap: 20px;
      }
      .bm-stats-total {
        text-align: center;
        min-width: 72px;
      }
      .bm-stats-total-value {
        font-size: 36px;
        font-weight: 700;
        line-height: 1.1;
      }
      .bm-stats-total-label {
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.04em;
        opacity: 0.6;
      }
      .bm-stats-problems {
        padding-top: 4px;
      }
      .bm-stats-table {
        flex: 1;
        border-collapse: collapse;
        font-size: 13px;
      }
      .bm-stats-table td {
        padding: 2px 6px;
      }
      .bm-stats-count {
        text-align: right;
        font-weight: 600;
        font-variant-numeric: tabular-nums;
      }
      .bm-sq {
        display: inline-block;
        width: 12px;
        height: 12px;
        border-radius: 2px;
        background: var(--bm-unknown);
      }
      .bm-sq--ok {
        background: var(--bm-green);
      }
      .bm-sq--warn {
        background: var(--bm-gold);
      }
      .bm-sq--crit {
        background: var(--bm-red);
      }
      .bm-sq--unknown {
        background: var(--bm-unknown);
      }
      @media (max-width: 900px) {
        .bm-stats-row {
          grid-template-columns: 1fr;
        }
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
      .bm-dashboard-section {
        display: block;
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

  servicesTotal = computed(() => {
    const s = this.servicesByState();
    return s.OK + s.WARN + s.CRIT + s.UNKNOWN;
  });

  /** CheckMK's host reachability breakdown, derived from the same
   * enrollment/last-seen heuristic every badge in the app uses
   * (agentHealthStatus): ok→Up, unknown/stale→Unreachable, crit
   * (revoked)→Down, warn (pending)→Pending. */
  hostStats = computed(() => {
    const counts = { ok: 0, unknown: 0, crit: 0, warn: 0 };
    for (const a of this.agents()) {
      counts[agentHealthStatus(a)]++;
    }
    return [
      { label: 'Up', count: counts.ok, color: 'var(--bm-green)' },
      { label: 'Unreachable', count: counts.unknown, color: 'var(--bm-unknown)' },
      { label: 'Down', count: counts.crit, color: 'var(--bm-red)' },
      { label: 'Pending', count: counts.warn, color: 'var(--bm-gold)' },
    ];
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
