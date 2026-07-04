import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { RouterLink } from '@angular/router';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { AgentService } from '../../core/services/agent.service';
import { RunService } from '../../core/services/run.service';
import { Agent } from '../../core/models/agent.model';
import { PlanRun } from '../../core/models/run.model';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { agentHealthStatus, runStatusBadge } from '../../shared/status.util';

/**
 * The fleet-wide summary landing page (see docs/plan.md's Bossman plan,
 * section C.1 "Fleet-Übersicht"). The plan called for Gridstack-based
 * draggable widgets; this v1 deliberately ships a fixed CSS-grid layout
 * of the same information instead — Bossman's REST API has no per-user
 * layout-preference storage yet, so a drag-customizable grid would have
 * nothing to persist to, and static cards cover the actual goal ("see
 * fleet health at a glance") without that extra machinery. Revisit once
 * there's a real preferences endpoint to back it.
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
            <div class="bm-summary-value">{{ agents().length }}</div>
            <div class="bm-summary-label">Hosts</div>
          </mat-card-content>
        </mat-card>
        <mat-card class="bm-summary-card">
          <mat-card-content>
            <div class="bm-summary-value bm-ok">{{ healthCounts().ok }}</div>
            <div class="bm-summary-label">Healthy</div>
          </mat-card-content>
        </mat-card>
        <mat-card class="bm-summary-card">
          <mat-card-content>
            <div class="bm-summary-value bm-warn">{{ healthCounts().warn }}</div>
            <div class="bm-summary-label">Pending</div>
          </mat-card-content>
        </mat-card>
        <mat-card class="bm-summary-card">
          <mat-card-content>
            <div class="bm-summary-value bm-unknown">{{ healthCounts().unknown }}</div>
            <div class="bm-summary-label">Unreachable</div>
          </mat-card-content>
        </mat-card>
        <mat-card class="bm-summary-card">
          <mat-card-content>
            <div class="bm-summary-value bm-crit">{{ healthCounts().crit }}</div>
            <div class="bm-summary-label">Revoked</div>
          </mat-card-content>
        </mat-card>
      </div>

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
        grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
        gap: 12px;
        margin-bottom: 20px;
      }
      .bm-summary-card mat-card-content {
        text-align: center;
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

  agents = signal<Agent[]>([]);
  recentRuns = signal<PlanRun[]>([]);

  healthCounts = computed(() => {
    const counts = { ok: 0, warn: 0, crit: 0, unknown: 0 };
    for (const agent of this.agents()) {
      counts[agentHealthStatus(agent)]++;
    }
    return counts;
  });

  ngOnInit(): void {
    this.agentService.list().subscribe((agents) => this.agents.set(agents));
    this.runService.list({ limit: 10 }).subscribe((runs) => this.recentRuns.set(runs));
  }

  statusOf(run: PlanRun) {
    return runStatusBadge(run.status);
  }
}
