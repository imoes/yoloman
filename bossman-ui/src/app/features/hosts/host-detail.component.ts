import { Component, OnInit, inject, signal } from '@angular/core';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { DatePipe, DecimalPipe } from '@angular/common';
import { MatTabsModule } from '@angular/material/tabs';
import { MatCardModule } from '@angular/material/card';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatSelectModule } from '@angular/material/select';
import { MatButtonModule } from '@angular/material/button';
import { MatDialog } from '@angular/material/dialog';
import { AgentService } from '../../core/services/agent.service';
import { RelationshipService } from '../../core/services/relationship.service';
import { RunService } from '../../core/services/run.service';
import { MonitoringService } from '../../core/services/monitoring.service';
import { Agent, MetricPoint } from '../../core/models/agent.model';
import { HostEdge } from '../../core/models/edge.model';
import { PlanRun } from '../../core/models/run.model';
import { FleetHost, ServiceHistoryPoint, ServiceState } from '../../core/models/monitoring.model';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { MetricChartComponent } from '../../shared/components/metric-chart/metric-chart.component';
import { TimeRangePickerComponent } from '../../shared/components/time-range-picker/time-range-picker.component';
import { PerfOMeterComponent } from '../../shared/components/perf-o-meter/perf-o-meter.component';
import { AcknowledgeDialogComponent } from '../../shared/components/acknowledge-dialog/acknowledge-dialog.component';
import { DowntimeDialogComponent, DowntimeDialogResult } from '../../shared/components/downtime-dialog/downtime-dialog.component';
import { agentHealthStatus, runStatusBadge, serviceStateBadge } from '../../shared/status.util';

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
    MatButtonModule,
    HostStatusBadgeComponent,
    MetricChartComponent,
    TimeRangePickerComponent,
    PerfOMeterComponent,
  ],
  template: `
    @if (agent(); as agent) {
      <div class="bm-page">
        <div class="bm-header-row">
          <h1>{{ agent.name }}</h1>
          <app-status-badge [status]="healthStatus()" [label]="agent.enrollment_state" />
        </div>

        <mat-tab-group>
          <mat-tab label="Overview">
            <div class="bm-tab-content">
              @if (overview(); as ov) {
                <div class="bm-overview-grid">
                  <mat-card class="bm-overview-tile">
                    <div class="bm-overview-label">CPU load</div>
                    <div class="bm-overview-value">{{ ov.cpu_load !== null ? ov.cpu_load.toFixed(2) : '—' }}</div>
                  </mat-card>
                  <mat-card class="bm-overview-tile">
                    <div class="bm-overview-label">Memory</div>
                    <app-perf-o-meter [value]="ov.mem_used_pct" [warn]="80" [crit]="90" />
                  </mat-card>
                  <mat-card class="bm-overview-tile">
                    <div class="bm-overview-label">Disk (max)</div>
                    <app-perf-o-meter [value]="ov.disk_used_pct_max" [warn]="80" [crit]="90" />
                  </mat-card>
                  <mat-card class="bm-overview-tile">
                    <div class="bm-overview-label">Services</div>
                    <div class="bm-service-counts">
                      @if (ov.service_counts['CRIT']) {
                        <span class="bm-count bm-count--crit">{{ ov.service_counts['CRIT'] }} CRIT</span>
                      }
                      @if (ov.service_counts['WARN']) {
                        <span class="bm-count bm-count--warn">{{ ov.service_counts['WARN'] }} WARN</span>
                      }
                      @if (ov.service_counts['OK']) {
                        <span class="bm-count bm-count--ok">{{ ov.service_counts['OK'] }} OK</span>
                      }
                      @if (!ov.service_counts['CRIT'] && !ov.service_counts['WARN'] && !ov.service_counts['OK']) {
                        <span class="bm-empty">No services yet</span>
                      }
                    </div>
                  </mat-card>
                </div>
                @if (ov.parent_name) {
                  <p class="bm-parent-note">
                    Behind proxy <a [routerLink]="['/hosts', ov.parent_agent_id]">{{ ov.parent_name }}</a>
                  </p>
                }
              } @else {
                <p class="bm-empty">No metric snapshot yet for this host.</p>
              }
            </div>
          </mat-tab>

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

          <mat-tab label="Services">
            <div class="bm-tab-content">
              @if (services().length) {
                <table class="bm-table">
                  <thead>
                    <tr>
                      <th>Service</th>
                      <th>State</th>
                      <th>Value</th>
                      <th>Since</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    @for (svc of services(); track svc.id) {
                      <tr [class.bm-row-selected]="selectedService()?.id === svc.id" class="bm-row-link" (click)="selectService(svc)">
                        <td>{{ svc.name }}</td>
                        <td><app-status-badge [status]="serviceBadge(svc)" [label]="svc.state" /></td>
                        <td>{{ svc.value !== null ? (svc.value | number: '1.0-2') : '—' }}</td>
                        <td>{{ svc.last_state_change | date: 'short' }}</td>
                        <td class="bm-actions">
                          @if (!svc.acknowledged) {
                            <button mat-button (click)="acknowledge(svc, $event)">Acknowledge</button>
                          } @else {
                            <button mat-button (click)="unacknowledge(svc, $event)">Unacknowledge</button>
                          }
                          <button mat-button (click)="scheduleDowntime(svc, $event)">Downtime</button>
                        </td>
                      </tr>
                    }
                  </tbody>
                </table>

                @if (selectedService(); as svc) {
                  <div class="bm-service-detail">
                    <h3>{{ svc.name }} — {{ svc.output }}</h3>
                    <app-metric-chart [points]="serviceMetricPoints()" [metricName]="svc.metric" />
                    @if (serviceHistory().length) {
                      <ul class="bm-history-list">
                        @for (h of serviceHistory(); track h.time) {
                          <li>
                            <app-status-badge [status]="historyBadge(h)" [label]="h.state" />
                            <span>{{ h.time | date: 'medium' }}</span>
                            @if (h.value !== null) {
                              <span class="bm-history-value">{{ h.value | number: '1.0-2' }}</span>
                            }
                          </li>
                        }
                      </ul>
                    }
                  </div>
                }
              } @else {
                <p class="bm-empty">No monitored services on this host yet — define a check rule in Settings.</p>
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
      .bm-actions {
        text-align: right;
        white-space: nowrap;
      }
      .bm-row-selected {
        background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent);
      }
      .bm-service-detail {
        margin-top: 20px;
      }
      .bm-history-list {
        list-style: none;
        padding: 0;
        margin-top: 12px;
        display: flex;
        flex-direction: column;
        gap: 4px;
        max-height: 220px;
        overflow-y: auto;
      }
      .bm-history-list li {
        display: flex;
        align-items: center;
        gap: 10px;
        padding: 4px 0;
        font-size: 13px;
      }
      .bm-history-value {
        opacity: 0.7;
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
      .bm-overview-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
        gap: 12px;
      }
      .bm-overview-tile {
        padding: 4px;
      }
      .bm-overview-tile mat-card-content,
      .bm-overview-tile {
        display: flex;
        flex-direction: column;
        gap: 8px;
        padding: 16px;
      }
      .bm-overview-label {
        font-size: 12px;
        text-transform: uppercase;
        letter-spacing: 0.04em;
        opacity: 0.7;
      }
      .bm-overview-value {
        font-size: 28px;
        font-weight: 600;
      }
      .bm-parent-note {
        margin-top: 16px;
        opacity: 0.8;
      }
      .bm-service-counts {
        display: flex;
        gap: 10px;
        flex-wrap: wrap;
      }
      .bm-count {
        font-size: 13px;
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
    `,
  ],
})
export class HostDetailComponent implements OnInit {
  private route = inject(ActivatedRoute);
  private agentService = inject(AgentService);
  private relationshipService = inject(RelationshipService);
  private runService = inject(RunService);
  private monitoringService = inject(MonitoringService);
  private dialog = inject(MatDialog);

  agent = signal<Agent | null>(null);
  metricNames = signal<string[]>([]);
  selectedMetric = signal<string | null>(null);
  metricPoints = signal<MetricPoint[]>([]);
  edges = signal<HostEdge[]>([]);
  runs = signal<PlanRun[]>([]);
  services = signal<ServiceState[]>([]);
  selectedService = signal<ServiceState | null>(null);
  serviceMetricPoints = signal<MetricPoint[]>([]);
  serviceHistory = signal<ServiceHistoryPoint[]>([]);
  overview = signal<FleetHost | null>(null);

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
    this.reloadServices(id);
    this.monitoringService.fleetHosts().subscribe((hosts) => this.overview.set(hosts.find((h) => h.id === id) ?? null));
  }

  private reloadServices(agentId: string): void {
    this.monitoringService.agentServices(agentId).subscribe((services) => {
      this.services.set(services);
      const selected = this.selectedService();
      if (selected) {
        const updated = services.find((s) => s.id === selected.id) ?? null;
        this.selectedService.set(updated);
      }
    });
  }

  selectService(svc: ServiceState): void {
    this.selectedService.set(svc);
    const agent = this.agent();
    if (!agent) return;
    this.agentService.metricSeries(agent.id, svc.metric, this.since).subscribe((res) => this.serviceMetricPoints.set(res.points));
    this.monitoringService.serviceHistory(agent.id, svc.name).subscribe((history) => this.serviceHistory.set(history));
  }

  serviceBadge(svc: ServiceState) {
    return serviceStateBadge(svc.state);
  }

  historyBadge(h: ServiceHistoryPoint) {
    return serviceStateBadge(h.state);
  }

  acknowledge(svc: ServiceState, event: Event): void {
    event.stopPropagation();
    const ref = this.dialog.open(AcknowledgeDialogComponent, {
      width: '420px',
      data: { serviceName: svc.name, hostName: svc.agent_name },
    });
    ref.afterClosed().subscribe((comment: string | undefined) => {
      if (comment === undefined) return;
      this.monitoringService.acknowledge(svc.id, comment).subscribe(() => this.reloadServices(svc.agent_id));
    });
  }

  unacknowledge(svc: ServiceState, event: Event): void {
    event.stopPropagation();
    this.monitoringService.unacknowledge(svc.id).subscribe(() => this.reloadServices(svc.agent_id));
  }

  scheduleDowntime(svc: ServiceState, event: Event): void {
    event.stopPropagation();
    const ref = this.dialog.open(DowntimeDialogComponent, {
      width: '420px',
      data: { hostName: svc.agent_name, serviceName: svc.name },
    });
    ref.afterClosed().subscribe((result: DowntimeDialogResult | undefined) => {
      if (!result) return;
      const now = new Date();
      const endsAt = new Date(now.getTime() + result.minutes * 60_000);
      this.monitoringService
        .createDowntime({
          agent_id: svc.agent_id,
          service_name: svc.name,
          starts_at: now.toISOString(),
          ends_at: endsAt.toISOString(),
          comment: result.comment,
        })
        .subscribe(() => this.reloadServices(svc.agent_id));
    });
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
