import { Component, OnInit, inject, signal } from '@angular/core';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { DatePipe, DecimalPipe } from '@angular/common';
import { MatTabsModule } from '@angular/material/tabs';
import { MatCardModule } from '@angular/material/card';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatSelectModule } from '@angular/material/select';
import { AgentService } from '../../core/services/agent.service';
import { RelationshipService } from '../../core/services/relationship.service';
import { RunService } from '../../core/services/run.service';
import { Agent, MetricPoint } from '../../core/models/agent.model';
import { HostEdge } from '../../core/models/edge.model';
import { PlanRun } from '../../core/models/run.model';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { MetricChartComponent } from '../../shared/components/metric-chart/metric-chart.component';
import { TimeRangePickerComponent } from '../../shared/components/time-range-picker/time-range-picker.component';
import { agentHealthStatus, runStatusBadge } from '../../shared/status.util';

@Component({
  selector: 'app-host-detail',
  standalone: true,
  imports: [
    RouterLink,
    DatePipe,
    DecimalPipe,
    MatTabsModule,
    MatCardModule,
    MatFormFieldModule,
    MatSelectModule,
    HostStatusBadgeComponent,
    MetricChartComponent,
    TimeRangePickerComponent,
  ],
  template: `
    @if (agent(); as agent) {
      <div class="bm-page">
        <div class="bm-header-row">
          <h1>{{ agent.name }}</h1>
          <app-status-badge [status]="healthStatus()" [label]="agent.enrollment_state" />
        </div>

        <mat-tab-group>
          <mat-tab label="Facts">
            <div class="bm-tab-content">
              <dl class="bm-facts">
                <dt>Address</dt>
                <dd>{{ agent.address || '—' }}</dd>
                <dt>Mode</dt>
                <dd>{{ agent.mode }}</dd>
                <dt>Enrollment state</dt>
                <dd>{{ agent.enrollment_state }}</dd>
                <dt>Last seen</dt>
                <dd>{{ agent.last_seen_at ? (agent.last_seen_at | date: 'medium') : 'never' }}</dd>
                <dt>Tags</dt>
                <dd>{{ hasTags(agent) ? tagsJson(agent) : '—' }}</dd>
              </dl>
            </div>
          </mat-tab>

          <mat-tab label="Metrics">
            <div class="bm-tab-content">
              <div class="bm-metric-controls">
                <mat-form-field appearance="outline">
                  <mat-label>Metric</mat-label>
                  <mat-select [value]="selectedMetric()" (selectionChange)="onMetricChange($event.value)">
                    @for (m of metricNames(); track m) {
                      <mat-option [value]="m">{{ m }}</mat-option>
                    }
                  </mat-select>
                </mat-form-field>
                <app-time-range-picker selectedRange="1h" (rangeChange)="onRangeChange($event)" />
              </div>
              @if (selectedMetric()) {
                <app-metric-chart [points]="metricPoints()" [metricName]="selectedMetric()!" />
              } @else {
                <p class="bm-empty">No metrics recorded for this host yet.</p>
              }
            </div>
          </mat-tab>

          <mat-tab label="Relationships">
            <div class="bm-tab-content">
              @if (edges().length) {
                <table class="bm-table">
                  <thead>
                    <tr>
                      <th>Process</th>
                      <th>Destination</th>
                      <th>Events</th>
                      <th>Latency (p50)</th>
                    </tr>
                  </thead>
                  <tbody>
                    @for (edge of edges(); track edge.dst_addr + edge.dst_port) {
                      <tr>
                        <td>{{ edge.src_comm }}</td>
                        <td>{{ edge.dst_addr }}:{{ edge.dst_port }}</td>
                        <td>{{ edge.event_count }}</td>
                        <td>{{ edge.latency_ms_p50 !== null ? (edge.latency_ms_p50 | number: '1.1-1') + ' ms' : '—' }}</td>
                      </tr>
                    }
                  </tbody>
                </table>
              } @else {
                <p class="bm-empty">No connections recorded for this host yet.</p>
              }
            </div>
          </mat-tab>

          <mat-tab label="Runs">
            <div class="bm-tab-content">
              @if (runs().length) {
                <table class="bm-table">
                  <thead>
                    <tr>
                      <th>Plan</th>
                      <th>Status</th>
                      <th>Started</th>
                    </tr>
                  </thead>
                  <tbody>
                    @for (run of runs(); track run.id) {
                      <tr [routerLink]="['/runs', run.id]" class="bm-row-link">
                        <td>{{ run.plan_name }}</td>
                        <td><app-status-badge [status]="runStatus(run)" [label]="run.status" /></td>
                        <td>{{ run.started_at | date: 'medium' }}</td>
                      </tr>
                    }
                  </tbody>
                </table>
              } @else {
                <p class="bm-empty">No plan runs against this host yet.</p>
              }
            </div>
          </mat-tab>
        </mat-tab-group>
      </div>
    }
  `,
  styles: [
    `
      .bm-page {
        padding: 24px;
        max-width: 1100px;
        margin: 0 auto;
      }
      .bm-header-row {
        display: flex;
        align-items: center;
        gap: 12px;
        margin-bottom: 8px;
      }
      .bm-tab-content {
        padding: 16px 4px;
      }
      .bm-facts {
        display: grid;
        grid-template-columns: 160px 1fr;
        row-gap: 8px;
      }
      .bm-facts dt {
        opacity: 0.7;
      }
      .bm-facts dd {
        margin: 0;
      }
      .bm-metric-controls {
        display: flex;
        align-items: center;
        gap: 16px;
        margin-bottom: 12px;
      }
      .bm-table {
        width: 100%;
        border-collapse: collapse;
      }
      .bm-table th {
        text-align: left;
        font-size: 12px;
        opacity: 0.7;
        padding: 8px 10px;
      }
      .bm-table td {
        padding: 8px 10px;
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
    `,
  ],
})
export class HostDetailComponent implements OnInit {
  private route = inject(ActivatedRoute);
  private agentService = inject(AgentService);
  private relationshipService = inject(RelationshipService);
  private runService = inject(RunService);

  agent = signal<Agent | null>(null);
  metricNames = signal<string[]>([]);
  selectedMetric = signal<string | null>(null);
  metricPoints = signal<MetricPoint[]>([]);
  edges = signal<HostEdge[]>([]);
  runs = signal<PlanRun[]>([]);

  healthStatus = signal(agentHealthStatus({ enrollment_state: 'pending', last_seen_at: null }));
  private since = new Date(Date.now() - 3_600_000).toISOString();

  ngOnInit(): void {
    const id = this.route.snapshot.paramMap.get('id')!;

    this.agentService.get(id).subscribe((agent) => {
      this.agent.set(agent);
      this.healthStatus.set(agentHealthStatus(agent));
    });

    this.agentService.metricNames(id).subscribe((res) => {
      this.metricNames.set(res.metrics);
      if (res.metrics.length && !this.selectedMetric()) {
        this.onMetricChange(res.metrics[0]);
      }
    });

    this.relationshipService.list(id).subscribe((edges) => this.edges.set(edges));
    this.runService.list({ agent_id: id }).subscribe((runs) => this.runs.set(runs));
  }

  onMetricChange(metric: string): void {
    this.selectedMetric.set(metric);
    this.loadMetricSeries();
  }

  onRangeChange(since: string): void {
    this.since = since;
    this.loadMetricSeries();
  }

  private loadMetricSeries(): void {
    const agent = this.agent();
    const metric = this.selectedMetric();
    if (!agent || !metric) return;
    this.agentService.metricSeries(agent.id, metric, this.since).subscribe((res) => this.metricPoints.set(res.points));
  }

  runStatus(run: PlanRun) {
    return runStatusBadge(run.status);
  }

  hasTags(agent: Agent): boolean {
    return Object.keys(agent.metadata ?? {}).length > 0;
  }

  tagsJson(agent: Agent): string {
    return JSON.stringify(agent.metadata);
  }
}
