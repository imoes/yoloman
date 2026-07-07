import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { DatePipe, DecimalPipe } from '@angular/common';
import { forkJoin } from 'rxjs';
import { MatTabsModule } from '@angular/material/tabs';
import { MatCardModule } from '@angular/material/card';
import { MatButtonToggleModule } from '@angular/material/button-toggle';
import { MatButtonModule } from '@angular/material/button';
import { MatDialog } from '@angular/material/dialog';
import { AgentService } from '../../core/services/agent.service';
import { RelationshipService } from '../../core/services/relationship.service';
import { RunService } from '../../core/services/run.service';
import { MonitoringService } from '../../core/services/monitoring.service';
import { Agent, LatestMetric, MetricPoint } from '../../core/models/agent.model';
import { HostEdge } from '../../core/models/edge.model';
import { PlanRun } from '../../core/models/run.model';
import { FleetHost, ServiceHistoryPoint, ServiceState } from '../../core/models/monitoring.model';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { ChartSeries, MetricChartComponent } from '../../shared/components/metric-chart/metric-chart.component';
import { MetricGaugeComponent } from '../../shared/components/metric-gauge/metric-gauge.component';
import { TimeRangePickerComponent } from '../../shared/components/time-range-picker/time-range-picker.component';
import { PerfOMeterComponent } from '../../shared/components/perf-o-meter/perf-o-meter.component';
import { AcknowledgeDialogComponent, AcknowledgeDialogResult } from '../../shared/components/acknowledge-dialog/acknowledge-dialog.component';
import { DowntimeDialogComponent, DowntimeDialogResult } from '../../shared/components/downtime-dialog/downtime-dialog.component';
import { HostInventoryComponent } from './host-inventory.component';
import { agentHealthStatus, runStatusBadge, serviceStateBadge } from '../../shared/status.util';

type MetricGroupName = 'CPU' | 'Memory' | 'Disk' | 'Network' | 'System' | 'Internal';

/** Zabbix groups latest data by "application"; we group by subsystem so the
 * useful telemetry sorts to the top and internal counters sink to the bottom
 * (and hide by default). */
const GROUP_ORDER: MetricGroupName[] = ['CPU', 'Memory', 'Disk', 'Network', 'System', 'Internal'];

function classifyMetric(name: string): MetricGroupName {
  if (name.startsWith('check_') || name.endsWith('_start')) return 'Internal';
  if (name.startsWith('cpu_')) return 'CPU';
  if (name.startsWith('mem_')) return 'Memory';
  if (name.startsWith('disk_')) return 'Disk';
  if (name.startsWith('net_')) return 'Network';
  return 'System';
}

/** Maps the Go agent's per-check state metric (`check_<x>_state`, whose value
 * is a Nagios code) onto the real metric it grades, so the State column is
 * coloured straight from the agent's own built-in checks even when no Bossman
 * CheckRule exists. Disk is special-cased below: any `check_disk_*_state`
 * grades the single collapsed `disk_used_pct` row. */
const CHECK_STATE_TARGET: Record<string, string> = {
  check_cpu_load_state: 'cpu_load1',
  check_memory_state: 'mem_used_pct',
  check_uptime_state: 'uptime_seconds',
};

function stateFromCode(v: number): ServiceState['state'] {
  return v >= 2 ? 'CRIT' : v >= 1 ? 'WARN' : 'OK';
}

const STATE_RANK = { OK: 0, UNKNOWN: 1, WARN: 2, CRIT: 3 } as const;

/** CheckMK-style combined graphs: metrics that belong together and are drawn
 * overlaid in one chart. Expanding any member shows the whole set. */
const COMBINED_GRAPHS: string[][] = [
  ['cpu_load1', 'cpu_load5', 'cpu_load15'],
  ['net_rx_bytes', 'net_tx_bytes'],
];

function familyMembers(metric: string): string[] {
  return COMBINED_GRAPHS.find((f) => f.includes(metric)) ?? [metric];
}

/** Where an agent-reported check's chart data comes from. Agent checks carry
 * an empty `metric` (their state arrives pre-computed), so we map the check by
 * name onto the real telemetry metric(s) it grades — otherwise the service
 * detail chart has nothing to plot ("no data"). Disk checks additionally pin
 * a mount, since all mounts share the one `disk_used_pct` series. */
function serviceMetricSpec(name: string, metric: string): { members: string[]; mount?: string } | null {
  if (metric) return { members: [metric] };
  if (name === 'CPU load') return { members: ['cpu_load1', 'cpu_load5', 'cpu_load15'] };
  if (name === 'Memory') return { members: ['mem_used_pct'] };
  if (name === 'Uptime') return { members: ['uptime_seconds'] };
  if (name.startsWith('Disk ')) return { members: ['disk_used_pct'], mount: name.slice('Disk '.length) };
  return null;
}

@Component({
  selector: 'app-host-detail',
  standalone: true,
  imports: [
    RouterLink,
    DatePipe,
    DecimalPipe,
    MatTabsModule,
    MatCardModule,
    MatButtonToggleModule,
    MatButtonModule,
    HostStatusBadgeComponent,
    HostInventoryComponent,
    MetricChartComponent,
    MetricGaugeComponent,
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

          <mat-tab label="Services">
            <div class="bm-tab-content">
              <!-- CheckMK-style services view (Block H3): every check as one
                   row — State | Service | Summary | Age | Checked |
                   Perf-O-Meter — expanding inline into the history chart.
                   The former separate "Metrics" tab lives on below as the
                   collapsible raw "Latest data" section (Zabbix's own
                   split: services grade, latest data is telemetry). -->
              @if (services().length) {
                <table class="bm-table bm-svc">
                  <thead>
                    <tr>
                      <th class="bm-col-state">State</th>
                      <th>Service</th>
                      <th class="bm-col-summary">Summary</th>
                      <th class="bm-col-age">Age</th>
                      <th class="bm-col-age">Checked</th>
                      <th class="bm-col-pom">Perf-O-Meter</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    @for (svc of services(); track svc.id) {
                      <tr
                        class="bm-row-link"
                        [class.bm-row-selected]="selectedService()?.id === svc.id"
                        (click)="toggleService(svc)"
                      >
                        <td class="bm-col-state">
                          <app-status-badge [status]="serviceBadge(svc)" [label]="svc.state" />
                          @if (svc.acknowledged) {
                            <span class="bm-flag" title="acknowledged">✔</span>
                          }
                          @if (svc.in_downtime) {
                            <span class="bm-flag" title="in downtime">⏸</span>
                          }
                        </td>
                        <td class="bm-svc-name">{{ svc.name }}</td>
                        <td class="bm-col-summary">{{ svc.output || '—' }}</td>
                        <td class="bm-col-age">{{ timeAgo(svc.last_state_change) }}</td>
                        <td class="bm-col-age">{{ timeAgo(svc.last_checked) }}</td>
                        <td class="bm-col-pom">
                          @if (serviceIsPct(svc) && svc.value !== null) {
                            <app-perf-o-meter [value]="svc.value" [warn]="80" [crit]="90" />
                          } @else if (svc.value !== null) {
                            <span class="bm-svc-value">{{ svc.value | number: '1.0-2' }}</span>
                          }
                        </td>
                        <td class="bm-actions">
                          @if (!svc.acknowledged) {
                            <button mat-button (click)="acknowledge(svc, $event)">Acknowledge</button>
                          } @else {
                            <button mat-button (click)="unacknowledge(svc, $event)">Unacknowledge</button>
                          }
                          <button mat-button (click)="scheduleDowntime(svc, $event)">Downtime</button>
                        </td>
                      </tr>
                      @if (selectedService()?.id === svc.id) {
                        <tr class="bm-expand-row">
                          <td colspan="7">
                            <div class="bm-metric-chart-wrap">
                              <app-metric-chart [series]="serviceChartSeries()" [metricName]="svc.name" />
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
                          </td>
                        </tr>
                      }
                    }
                  </tbody>
                </table>
              } @else {
                <p class="bm-empty">No monitored services on this host yet — define a check rule in Settings.</p>
              }

              <div class="bm-raw-toggle">
                <button mat-button (click)="showRaw.set(!showRaw())">
                  {{ showRaw() ? '▾ Hide' : '▸ Show' }} latest data ({{ shownCount() }} metrics)
                </button>
              </div>

              @if (showRaw() && latestMetrics().length) {
                <!-- CheckMK/Zabbix "Latest data": every metric in a list (not a
                     dropdown), grouped by subsystem, with a coloured check-state
                     column, inline Perf-O-Meters for percentages, and each row
                     expanding into a CentralStation-style gauge + green history
                     chart. Internal bookkeeping counters are hidden by default. -->
                <div class="bm-metric-toolbar">
                  <mat-button-toggle-group
                    [value]="metricFilter()"
                    (change)="metricFilter.set($event.value)"
                    aria-label="Metric state filter"
                  >
                    <mat-button-toggle value="all">All ({{ shownCount() }})</mat-button-toggle>
                    <mat-button-toggle value="crit" [disabled]="!stateCounts().CRIT">
                      Critical ({{ stateCounts().CRIT }})
                    </mat-button-toggle>
                    <mat-button-toggle value="warn" [disabled]="!stateCounts().WARN">
                      Warnings ({{ stateCounts().WARN }})
                    </mat-button-toggle>
                  </mat-button-toggle-group>
                  @if (internalCount()) {
                    <button mat-button class="bm-internal-toggle" (click)="showInternal.set(!showInternal())">
                      {{ showInternal() ? 'Hide' : 'Show' }} internal ({{ internalCount() }})
                    </button>
                  }
                </div>

                @if (visibleGroups().length) {
                  <table class="bm-table bm-latest">
                    <thead>
                      <tr>
                        <th class="bm-col-state">State</th>
                        <th>Metric</th>
                        <th class="bm-col-value">Last value</th>
                        <th class="bm-col-check">Last check</th>
                        <th class="bm-col-expand"></th>
                      </tr>
                    </thead>
                    <tbody>
                      @for (grp of visibleGroups(); track grp.group) {
                        <tr class="bm-group-row">
                          <td class="bm-col-state">
                            @if (grp.state) {
                              <app-status-badge [status]="stateBadge(grp.state)" [label]="grp.state" />
                            }
                          </td>
                          <td colspan="4" class="bm-group-name">{{ grp.group }}</td>
                        </tr>
                        @for (row of grp.rows; track row.metric) {
                          <tr
                            class="bm-row-link"
                            [class.bm-row-selected]="expandedMetric() === row.metric"
                            (click)="toggleMetric(row.metric)"
                          >
                            <td class="bm-col-state">
                              @if (row.state) {
                                <app-status-badge [status]="stateBadge(row.state)" [label]="row.state" />
                              } @else {
                                <span class="bm-nostate" title="No check covers this metric">—</span>
                              }
                            </td>
                            <td class="bm-metric-name">{{ row.metric }}</td>
                            <td class="bm-col-value">
                              @if (row.isPct) {
                                <app-perf-o-meter [value]="row.value" [warn]="80" [crit]="90" />
                              } @else {
                                {{ formatValue(row.metric, row.value) }}
                              }
                            </td>
                            <td class="bm-col-check">{{ timeAgo(row.time) }}</td>
                            <td class="bm-col-expand">{{ expandedMetric() === row.metric ? '▾' : '▸' }}</td>
                          </tr>
                          @if (expandedMetric() === row.metric) {
                            <tr class="bm-expand-row">
                              <td colspan="5">
                                <div class="bm-metric-expand" [class.bm-metric-expand--gauge]="row.isPct">
                                  @if (row.isPct) {
                                    <app-metric-gauge [value]="row.value" [warn]="80" [crit]="90" [label]="row.metric" />
                                  }
                                  <div class="bm-metric-chart-wrap">
                                    <app-time-range-picker selectedRange="1h" (rangeChange)="onRangeChange($event)" />
                                    <app-metric-chart
                                      [points]="metricPoints()"
                                      [series]="chartSeries()"
                                      [metricName]="row.metric"
                                    />
                                  </div>
                                </div>
                              </td>
                            </tr>
                          }
                        }
                      }
                    </tbody>
                  </table>
                } @else {
                  <p class="bm-empty">
                    No metrics in {{ metricFilter() === 'crit' ? 'critical' : 'warning' }} state — everything healthy.
                  </p>
                }
              }
            </div>
          </mat-tab>

          <mat-tab label="Inventory">
            <div class="bm-tab-content">
              <app-host-inventory [agent]="agent" />
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
      .bm-svc .bm-col-summary {
        max-width: 420px;
        font-size: 13px;
        opacity: 0.85;
      }
      .bm-svc .bm-col-age {
        width: 84px;
        white-space: nowrap;
        opacity: 0.7;
        font-size: 13px;
      }
      .bm-svc .bm-col-pom {
        width: 160px;
      }
      .bm-svc-name {
        font-weight: 500;
        white-space: nowrap;
      }
      .bm-svc-value {
        font-variant-numeric: tabular-nums;
        font-weight: 600;
      }
      .bm-flag {
        margin-left: 6px;
        font-size: 12px;
        opacity: 0.75;
      }
      .bm-raw-toggle {
        margin-top: 18px;
        border-top: 1px solid var(--mat-sys-outline-variant);
        padding-top: 6px;
      }
      .bm-metric-toolbar {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
        margin-bottom: 16px;
      }
      .bm-internal-toggle {
        font-size: 12px;
        opacity: 0.75;
      }
      .bm-group-row td {
        border-top: 2px solid var(--mat-sys-outline-variant);
        padding-top: 14px;
        padding-bottom: 4px;
      }
      .bm-group-name {
        font-size: 11px;
        font-weight: 700;
        text-transform: uppercase;
        letter-spacing: 0.08em;
        opacity: 0.65;
      }
      .bm-latest .bm-col-state {
        width: 96px;
      }
      .bm-latest .bm-col-value {
        text-align: right;
        white-space: nowrap;
        font-variant-numeric: tabular-nums;
        font-weight: 600;
        min-width: 150px;
      }
      .bm-latest .bm-col-value app-perf-o-meter {
        display: inline-flex;
        justify-content: flex-end;
        width: 100%;
      }
      .bm-metric-expand {
        display: flex;
        gap: 20px;
        padding: 8px 4px 16px;
        align-items: stretch;
      }
      .bm-metric-expand--gauge app-metric-gauge {
        flex: 0 0 200px;
      }
      .bm-metric-expand .bm-metric-chart-wrap {
        flex: 1;
        min-width: 0;
      }
      .bm-latest .bm-col-check {
        width: 110px;
        white-space: nowrap;
        opacity: 0.7;
      }
      .bm-latest .bm-col-expand {
        width: 28px;
        text-align: center;
        opacity: 0.6;
      }
      .bm-metric-name {
        font-family: var(--bm-mono, monospace);
        font-size: 13px;
      }
      .bm-nostate {
        opacity: 0.4;
      }
      .bm-expand-row td {
        border-top: none;
        background: color-mix(in srgb, var(--mat-sys-primary) 4%, transparent);
      }
      .bm-metric-chart-wrap {
        display: flex;
        flex-direction: column;
        gap: 12px;
        padding: 8px 4px 16px;
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
  selectedMetric = signal<string | null>(null);
  metricPoints = signal<MetricPoint[]>([]);
  chartSeries = signal<ChartSeries[]>([]);
  latestMetrics = signal<LatestMetric[]>([]);
  metricFilter = signal<'all' | 'crit' | 'warn'>('all');
  expandedMetric = signal<string | null>(null);
  showInternal = signal(false);
  /** The raw "Latest data" section under the Services table (the former
   * separate Metrics tab), collapsed by default. */
  showRaw = signal(false);

  /** Per-metric check state, from two sources merged worst-wins: (1) Bossman
   * CheckRule-derived services (which carry a populated `metric`), and (2) the
   * Go agent's own built-in `check_*_state` metrics mapped onto the metric
   * they grade. So the State column is coloured from real checks even before
   * anyone defines a custom rule. */
  private stateByMetric = computed(() => {
    const map: Record<string, ServiceState['state']> = {};
    const worst = (metric: string, state: ServiceState['state']) => {
      const prev = map[metric];
      if (prev === undefined || STATE_RANK[state] > STATE_RANK[prev]) map[metric] = state;
    };
    for (const svc of this.services()) {
      if (svc.metric) worst(svc.metric, svc.state);
    }
    for (const m of this.latestMetrics()) {
      if (!m.metric.startsWith('check_') || !m.metric.endsWith('_state')) continue;
      const target = m.metric.startsWith('check_disk_') ? 'disk_used_pct' : CHECK_STATE_TARGET[m.metric];
      if (target) worst(target, stateFromCode(m.value));
    }
    return map;
  });

  /** Every metric enriched with its subsystem group, derived check state, and
   * whether it's a percentage (→ inline Perf-O-Meter + gauge). */
  private enrichedRows = computed(() =>
    this.latestMetrics().map((m) => ({
      ...m,
      group: classifyMetric(m.metric),
      state: this.stateByMetric()[m.metric] ?? null,
      isPct: m.metric.endsWith('_pct'),
    })),
  );

  /** Rows eligible for the list before the state filter: internal counters are
   * dropped unless the operator opts to show them. */
  private baseRows = computed(() => {
    const showInt = this.showInternal();
    return this.enrichedRows().filter((r) => showInt || r.group !== 'Internal');
  });

  shownCount = computed(() => this.baseRows().length);
  internalCount = computed(() => this.enrichedRows().filter((r) => r.group === 'Internal').length);

  stateCounts = computed(() => {
    const counts = { CRIT: 0, WARN: 0 };
    for (const r of this.enrichedRows()) {
      if (r.group === 'Internal') continue;
      if (r.state === 'CRIT') counts.CRIT++;
      else if (r.state === 'WARN') counts.WARN++;
    }
    return counts;
  });

  /** The list, grouped by subsystem in GROUP_ORDER and filtered by the
   * All/Critical/Warnings toggle; each group carries its worst-child state for
   * the header badge. Empty groups are dropped. */
  visibleGroups = computed(() => {
    const filter = this.metricFilter();
    let rows = this.baseRows();
    if (filter === 'crit') rows = rows.filter((r) => r.state === 'CRIT');
    else if (filter === 'warn') rows = rows.filter((r) => r.state === 'WARN');
    return GROUP_ORDER.map((group) => {
      const grpRows = rows.filter((r) => r.group === group);
      let state: ServiceState['state'] | null = null;
      for (const r of grpRows) {
        if (r.state && (state === null || STATE_RANK[r.state] > STATE_RANK[state])) state = r.state;
      }
      return { group, rows: grpRows, state };
    }).filter((g) => g.rows.length > 0);
  });
  edges = signal<HostEdge[]>([]);
  runs = signal<PlanRun[]>([]);
  services = signal<ServiceState[]>([]);
  selectedService = signal<ServiceState | null>(null);
  serviceChartSeries = signal<ChartSeries[]>([]);
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

    this.agentService.metricsLatest(id).subscribe((res) => this.latestMetrics.set(res.metrics));

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

  /** Expand/collapse a service row inline (CheckMK-style, Block H3) —
   * expanding loads its chart + state history via selectService. */
  toggleService(svc: ServiceState): void {
    if (this.selectedService()?.id === svc.id) {
      this.selectedService.set(null);
      return;
    }
    this.selectService(svc);
  }

  /** True when the service grades a percentage metric — those rows get a
   * CheckMK Perf-O-Meter instead of a bare number. */
  serviceIsPct(svc: ServiceState): boolean {
    const spec = serviceMetricSpec(svc.name, svc.metric);
    return !!spec && spec.members[0].endsWith('_pct');
  }

  selectService(svc: ServiceState): void {
    this.selectedService.set(svc);
    const agent = this.agent();
    if (!agent) return;
    this.serviceChartSeries.set([]);
    const spec = serviceMetricSpec(svc.name, svc.metric);
    if (spec) {
      forkJoin(spec.members.map((m) => this.agentService.metricSeries(agent.id, m, this.since))).subscribe((results) => {
        const series = results.map((res, i) => ({
          name: spec.mount ? `${spec.members[i]} ${spec.mount}` : spec.members[i],
          points: spec.mount ? res.points.filter((p) => p.labels['mount'] === spec.mount) : res.points,
        }));
        this.serviceChartSeries.set(series);
      });
    }
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
    ref.afterClosed().subscribe((result: AcknowledgeDialogResult | undefined) => {
      if (!result) return;
      this.monitoringService
        .acknowledge(svc.id, result.comment, result.expireAfterMinutes)
        .subscribe(() => this.reloadServices(svc.agent_id));
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

  /** Expand/collapse a metric row into its full history chart. Only one row
   * is expanded at a time — collapsing frees the chart, expanding lazily
   * loads that metric's series. */
  toggleMetric(metric: string): void {
    if (this.expandedMetric() === metric) {
      this.expandedMetric.set(null);
      return;
    }
    this.expandedMetric.set(metric);
    this.selectedMetric.set(metric);
    this.loadMetricSeries();
  }

  stateBadge(state: ServiceState['state']) {
    return serviceStateBadge(state);
  }

  /** Zabbix-style unit conversion for the "Last value" column: bytes become
   * KiB/MiB/…, percentages get a %, uptime becomes a duration, load stays
   * two-decimal — so the list reads like a monitoring tool, not raw floats. */
  formatValue(metric: string, value: number): string {
    if (metric.endsWith('_pct')) return `${value.toFixed(1)} %`;
    if (metric.endsWith('_bytes')) return this.humanBytes(value);
    if (metric === 'uptime_seconds') return this.humanDuration(value);
    if (metric.startsWith('cpu_load')) return value.toFixed(2);
    return Number.isInteger(value) ? String(value) : value.toFixed(2);
  }

  private humanBytes(bytes: number): string {
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
    let v = bytes;
    let i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return `${v.toFixed(i === 0 ? 0 : 1)} ${units[i]}`;
  }

  private humanDuration(seconds: number): string {
    const d = Math.floor(seconds / 86400);
    const h = Math.floor((seconds % 86400) / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    if (d > 0) return `${d}d ${h}h`;
    if (h > 0) return `${h}h ${m}m`;
    return `${m}m`;
  }

  /** Elapsed-time label for the "Last check" column (Zabbix's own idiom). */
  timeAgo(iso: string): string {
    const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
    if (s < 60) return `${s}s ago`;
    if (s < 3600) return `${Math.floor(s / 60)}m ago`;
    if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
    return `${Math.floor(s / 86400)}d ago`;
  }

  onRangeChange(since: string): void {
    this.since = since;
    this.loadMetricSeries();
  }

  private loadMetricSeries(): void {
    const agent = this.agent();
    const metric = this.selectedMetric();
    if (!agent || !metric) return;
    const members = familyMembers(metric);
    if (members.length > 1) {
      // Combined graph (e.g. cpu_load1/5/15): overlay all members, no single line.
      this.metricPoints.set([]);
      forkJoin(members.map((m) => this.agentService.metricSeries(agent.id, m, this.since))).subscribe((results) => {
        this.chartSeries.set(results.map((res, i) => ({ name: members[i], points: res.points })));
      });
    } else {
      this.chartSeries.set([]);
      this.agentService.metricSeries(agent.id, metric, this.since).subscribe((res) => this.metricPoints.set(res.points));
    }
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
