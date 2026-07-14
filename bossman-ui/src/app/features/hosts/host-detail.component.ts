import { Component, OnInit, computed, inject, signal, viewChild } from '@angular/core';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { DatePipe, DecimalPipe } from '@angular/common';
import { forkJoin } from 'rxjs';
import { MatTabsModule, MatTabChangeEvent } from '@angular/material/tabs';
import { MatCardModule } from '@angular/material/card';
import { MatButtonToggleModule } from '@angular/material/button-toggle';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatDialog } from '@angular/material/dialog';
import { AgentService } from '../../core/services/agent.service';
import { RelationshipService } from '../../core/services/relationship.service';
import { RunService } from '../../core/services/run.service';
import { MonitoringService } from '../../core/services/monitoring.service';
import { Agent, EbpfDetail, LatestMetric, MetricPoint, Process } from '../../core/models/agent.model';
import { HostEdge } from '../../core/models/edge.model';
import { PlanRun } from '../../core/models/run.model';
import { Availability, FleetHost, ServiceHistoryPoint, ServiceState } from '../../core/models/monitoring.model';
import { BM_GREEN, BM_GOLD, BM_RED, BM_UNKNOWN } from '../../shared/bm-colors';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { ChartSeries, MetricChartComponent } from '../../shared/components/metric-chart/metric-chart.component';
import { MetricGaugeComponent } from '../../shared/components/metric-gauge/metric-gauge.component';
import { TimeRangePickerComponent } from '../../shared/components/time-range-picker/time-range-picker.component';
import { PerfOMeterComponent } from '../../shared/components/perf-o-meter/perf-o-meter.component';
import { AcknowledgeDialogComponent, AcknowledgeDialogResult } from '../../shared/components/acknowledge-dialog/acknowledge-dialog.component';
import { DowntimeDialogComponent, DowntimeDialogResult } from '../../shared/components/downtime-dialog/downtime-dialog.component';
import { ThresholdDialogComponent } from '../../shared/components/threshold-dialog/threshold-dialog.component';
import { HostInventoryComponent } from './host-inventory.component';
import { LatencyHeatmapComponent } from './latency-heatmap.component';
import { HostChecksComponent } from './host-checks.component';
import { HostConsoleComponent } from './host-console.component';
import { TopologyComponent } from '../topology/topology.component';
import { HostManagementComponent } from './management/host-management.component';
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
    MatIconModule,
    HostStatusBadgeComponent,
    HostInventoryComponent,
    HostChecksComponent,
    HostConsoleComponent,
    TopologyComponent,
    HostManagementComponent,
    MetricChartComponent,
    MetricGaugeComponent,
    TimeRangePickerComponent,
    PerfOMeterComponent,
    LatencyHeatmapComponent,
  ],
  template: `
    @if (agent(); as agent) {
      <div class="bm-page">
        <div class="bm-header-row">
          <h1>{{ agent.name }}</h1>
          <app-status-badge [status]="healthStatus()" [label]="agent.enrollment_state" />
        </div>

        <mat-tab-group [selectedIndex]="initialTabIndex" (selectedTabChange)="onTabChange($event)">
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
                          @if (svc.state !== 'OK' && svc.state_type === 'soft') {
                            <span class="bm-flag bm-flag--soft" title="soft state — not yet confirmed as a problem">
                              soft {{ svc.attempt }}/{{ svc.max_attempts }}
                            </span>
                          }
                          @if (svc.is_flapping) {
                            <span class="bm-flag bm-flag--flap" title="flapping — changing state too often">flapping</span>
                          }
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
                          <button mat-button (click)="overrideThreshold(svc, $event)" title="Set a warn/crit threshold for this service on this host">
                            Threshold
                          </button>
                        </td>
                      </tr>
                      @if (selectedService()?.id === svc.id) {
                        <tr class="bm-expand-row">
                          <td colspan="7">
                            <div class="bm-metric-chart-wrap">
                              <div class="bm-svc-ranges">
                                @for (r of availabilityRanges; track r.hours) {
                                  <button
                                    mat-button
                                    class="bm-avail-range"
                                    [class.bm-avail-range--on]="availabilityHours() === r.hours"
                                    (click)="setServiceRange(r.hours)"
                                  >
                                    {{ r.label }}
                                  </button>
                                }
                              </div>
                              <app-metric-chart
                                [series]="serviceChartSeries()"
                                [metricName]="svc.name"
                                [windowStartMs]="serviceChartWindow()?.start ?? null"
                                [windowEndMs]="serviceChartWindow()?.end ?? null"
                              />
                              @if (availability(); as av) {
                                <div class="bm-avail">
                                  <div class="bm-avail-head">
                                    <span class="bm-avail-title">Availability</span>
                                    <span class="bm-avail-ok">{{ av.ok_percent | number: '1.2-3' }}% OK</span>
                                  </div>
                                  @if (av.monitored_seconds > 0) {
                                    <div class="bm-avail-bar">
                                      @for (s of av.slices; track s.state) {
                                        @if (s.percent > 0) {
                                          <span
                                            class="bm-avail-seg"
                                            [style.width.%]="s.percent"
                                            [style.background]="availabilityColor(s.state)"
                                            [title]="s.state + ' ' + (s.percent | number: '1.1-1') + '%'"
                                          ></span>
                                        }
                                      }
                                    </div>
                                    <ul class="bm-avail-legend">
                                      @for (s of av.slices; track s.state) {
                                        @if (s.percent > 0) {
                                          <li>
                                            <span class="bm-avail-dot" [style.background]="availabilityColor(s.state)"></span>
                                            {{ s.state }} {{ s.percent | number: '1.2-2' }}%
                                          </li>
                                        }
                                      }
                                      <li class="bm-avail-changes">{{ av.state_changes }} state changes</li>
                                    </ul>
                                  } @else {
                                    <p class="bm-empty">No state history recorded in this window yet.</p>
                                  }
                                </div>
                              }
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
                <dd>{{ modeLabel(agent.mode) }}</dd>
                <dt>Enrollment state</dt>
                <dd>{{ agent.enrollment_state }}</dd>
                <dt>Last seen</dt>
                <dd>{{ agent.last_seen_at ? (agent.last_seen_at | date: 'medium') : 'never' }}</dd>
                <dt>Tags</dt>
                <dd>{{ hasTags(agent) ? tagsJson(agent) : '—' }}</dd>
              </dl>
            </div>
          </mat-tab>

          <mat-tab label="Checks">
            <div class="bm-tab-content">
              <app-host-checks [agent]="agent" />
            </div>
          </mat-tab>

          <mat-tab label="Console">
            <!-- Lazy: the WebSocket/PTY only opens when this tab is selected. -->
            <ng-template matTabContent>
              <div class="bm-tab-content">
                <div class="bm-console-actions">
                  <button mat-stroked-button (click)="openConsoleWindow()">
                    <mat-icon>open_in_new</mat-icon> Open in new window
                  </button>
                  <span class="bm-dim">Opens a stand-alone console window — you can open several.</span>
                </div>
                <app-host-console [agent]="agent" />
              </div>
            </ng-template>
          </mat-tab>

          <mat-tab label="Relationships">
            <div class="bm-tab-content">
              <div class="bm-rel-map"><app-topology [agentId]="agent.id" /></div>
              <h3 class="bm-rel-h">Connections</h3>
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

          <mat-tab label="eBPF">
            <div class="bm-tab-content">
              <p class="bm-dim">Kernel-level (eBPF) signals. The heatmaps show the latency <em>distribution</em>
                (buckets × time, color = event count); the tables below show <em>which</em> connections and
                disk I/O those events are — click a row to filter both tables by that process.</p>
              <div class="bm-ebpf-grid">
                <app-latency-heatmap [agentId]="agent.id" metric="conn_latency_bucket" title="Outbound connect latency" />
                <app-latency-heatmap [agentId]="agent.id" metric="disk_io_latency_bucket" title="Disk I/O latency" />
              </div>
              @if (ebpfFilter()) {
                <div class="bm-ebpf-filterbar">
                  <span>Filtered by process</span>
                  <span class="bm-ebpf-chip bm-mono">{{ ebpfFilter() }}
                    <button type="button" class="bm-ebpf-chip-x" (click)="ebpfFilter.set(null)" aria-label="Clear filter">×</button>
                  </span>
                </div>
              }
              <div class="bm-ebpf-grid">
                <div class="bm-ebpf-panel">
                  <div class="bm-ebpf-h">Top outbound connections <span class="bm-dim">(eBPF window)</span></div>
                  @if (filteredTalkers().length) {
                    <table class="bm-table bm-ebpf-tbl">
                      <thead><tr><th>Process</th><th>Destination</th><th class="bm-num">Connects</th></tr></thead>
                      <tbody>
                        @for (t of filteredTalkers(); track t.comm + t.dst_addr + t.dst_port) {
                          <tr class="bm-ebpf-row" [class.bm-ebpf-row-sel]="ebpfFilter() === t.comm" (click)="toggleEbpfFilter(t.comm)">
                            <td class="bm-mono">{{ t.comm }}</td><td class="bm-mono">{{ t.dst_addr }}:{{ t.dst_port }}</td><td class="bm-num">{{ t.count }}</td>
                          </tr>
                        }
                      </tbody>
                    </table>
                  } @else if (ebpf()?.top_talkers?.length) {
                    <p class="bm-empty">No connections from <span class="bm-mono">{{ ebpfFilter() }}</span> in this window.</p>
                  } @else { <p class="bm-empty">No connections observed in the eBPF window.</p> }
                </div>
                <div class="bm-ebpf-panel">
                  <div class="bm-ebpf-h">Slowest disk I/O <span class="bm-dim">(recent, by latency)</span></div>
                  @if (filteredDiskIo().length) {
                    <table class="bm-table bm-ebpf-tbl">
                      <thead><tr><th>Process</th><th>Op</th><th class="bm-num">Latency</th></tr></thead>
                      <tbody>
                        @for (d of filteredDiskIo(); track $index) {
                          <tr class="bm-ebpf-row" [class.bm-ebpf-row-sel]="ebpfFilter() === d.comm" (click)="toggleEbpfFilter(d.comm)">
                            <td class="bm-mono">{{ d.comm }}</td><td class="bm-mono">{{ d.rwbs || '—' }}</td><td class="bm-num">{{ (d.latency_ns / 1e6) | number: '1.2-2' }} ms</td>
                          </tr>
                        }
                      </tbody>
                    </table>
                  } @else if (ebpf()?.slowest_disk_io?.length) {
                    <p class="bm-empty">No disk I/O from <span class="bm-mono">{{ ebpfFilter() }}</span> in this window.</p>
                  } @else { <p class="bm-empty">No disk I/O observed in the eBPF window.</p> }
                </div>
              </div>
            </div>
          </mat-tab>

          <mat-tab label="Processes">
            <div class="bm-tab-content">
              <!-- Block J2: safe systemd service control (restart/stop/start)
                   via the agent's write-gated + audited systemd module. -->
              <div class="bm-svc-control">
                <span class="bm-svc-label">Service control (systemd):</span>
                <input
                  class="bm-svc-input"
                  type="text"
                  placeholder="unit name, e.g. nginx"
                  [value]="svcName()"
                  (input)="svcName.set($any($event.target).value)"
                  [disabled]="svcBusy()"
                />
                <button mat-stroked-button (click)="controlService('restart')" [disabled]="svcBusy() || !svcName().trim()">Restart</button>
                <button mat-stroked-button (click)="controlService('stop')" [disabled]="svcBusy() || !svcName().trim()">Stop</button>
                <button mat-stroked-button (click)="controlService('start')" [disabled]="svcBusy() || !svcName().trim()">Start</button>
                @if (svcMsg()) {
                  <span class="bm-svc-ok">{{ svcMsg() }}</span>
                }
                @if (svcErr()) {
                  <span class="bm-svc-err">{{ svcErr() }}</span>
                }
              </div>
              <div class="bm-proc-toolbar">
                <input
                  class="bm-proc-filter"
                  type="text"
                  placeholder="Filter by command, user or pid…"
                  [value]="processFilter()"
                  (input)="processFilter.set($any($event.target).value)"
                />
                <button mat-button (click)="loadProcesses()" [disabled]="processesLoading()">↻ Refresh</button>
                <label class="bm-proc-idle">
                  <input type="checkbox" [checked]="hideIdleProcesses()"
                         (change)="hideIdleProcesses.set($any($event.target).checked)" />
                  Hide idle (0 CPU &amp; 0 MEM)
                </label>
                @if (processesLoaded()) {
                  <span class="bm-proc-meta">{{ visibleProcesses().length }} of {{ processCount() }} processes · {{ sampleWindowMs() }}ms sample</span>
                }
              </div>

              @if (processesLoading()) {
                <p class="bm-empty">Sampling the process table…</p>
              } @else if (visibleProcesses().length) {
                <table class="bm-table bm-proc">
                  <thead>
                    <tr>
                      <th class="bm-num bm-sortable" [class.bm-sorted]="processSort() === 'pid'" (click)="sortBy('pid')">PID{{ sortArrow('pid') }}</th>
                      <th class="bm-sortable" [class.bm-sorted]="processSort() === 'user'" (click)="sortBy('user')">User{{ sortArrow('user') }}</th>
                      <th class="bm-num bm-sortable" [class.bm-sorted]="processSort() === 'cpu'" (click)="sortBy('cpu')">CPU %{{ sortArrow('cpu') }}</th>
                      <th class="bm-num bm-sortable" [class.bm-sorted]="processSort() === 'rss'" (click)="sortBy('rss')">Memory{{ sortArrow('rss') }}</th>
                      <th class="bm-num">Thr</th>
                      <th>S</th>
                      <th>Command</th>
                    </tr>
                  </thead>
                  <tbody>
                    @for (p of visibleProcesses(); track p.pid) {
                      <tr class="bm-row" [class.bm-row-selected]="expandedPid() === p.pid" (click)="toggleProcess(p)">
                        <td class="bm-num">{{ p.pid }}</td>
                        <td>{{ p.user || p.uid }}</td>
                        <td class="bm-num">
                          <span class="bm-proc-cpu">
                            <span class="bm-proc-cpu-bar" [style.width.%]="cpuBarWidth(p)" [style.background]="cpuColor(p)"></span>
                            <span class="bm-proc-cpu-val">{{ p.cpu_percent | number: '1.1-1' }}</span>
                          </span>
                        </td>
                        <td class="bm-num">{{ formatKiB(p.rss_kib) }}</td>
                        <td class="bm-num">{{ p.num_threads }}</td>
                        <td>{{ p.state }}</td>
                        <td class="bm-proc-cmd">
                          @if (p.container_id) {
                            <span class="bm-proc-container" title="{{ p.container_id }}">🐳 {{ shortContainer(p.container_id) }}</span>
                          }
                          @if (p.connections?.length) {
                            <span class="bm-proc-connbadge" title="outbound connections">⇄ {{ p.connections?.length }}</span>
                          }
                          {{ p.command }}
                        </td>
                      </tr>
                      @if (expandedPid() === p.pid) {
                        <tr class="bm-expand-row">
                          <td colspan="7">
                            <div class="bm-proc-detail">
                              <dl class="bm-facts">
                                <dt>PPID</dt>
                                <dd>{{ p.ppid }}</dd>
                                <dt>Comm</dt>
                                <dd>{{ p.comm }}</dd>
                                @if (p.container_id) {
                                  <dt>Container</dt>
                                  <dd>{{ p.container_id }}</dd>
                                }
                              </dl>
                              @if (p.connections?.length) {
                                <div class="bm-proc-conns">
                                  <strong>Talks to (eBPF)</strong>
                                  <ul>
                                    @for (c of p.connections; track c.dst_addr + c.dst_port) {
                                      <li>
                                        {{ c.dst_addr }}:{{ c.dst_port }}
                                        <span class="bm-proc-connstate">{{ c.state }}</span>
                                      </li>
                                    }
                                  </ul>
                                </div>
                              } @else {
                                <p class="bm-empty">No eBPF-observed connections (eBPF may be off on this host).</p>
                              }
                            </div>
                          </td>
                        </tr>
                      }
                    }
                  </tbody>
                </table>
              } @else if (processesLoaded()) {
                <p class="bm-empty">No processes match the filter.</p>
              } @else {
                <p class="bm-empty">Open this tab to sample the live process list.</p>
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

          <!-- Block J4: Cockpit-like host management (Services/Logs/Accounts/
               Storage/Network). Each inner section pulls its live data lazily. -->
          <mat-tab label="Management">
            <div class="bm-tab-content">
              <app-host-management [agentId]="agent.id" />
            </div>
          </mat-tab>
        </mat-tab-group>
      </div>
    }
  `,
  styles: [
    `
      .bm-svc-control {
        display: flex;
        align-items: center;
        gap: 8px;
        flex-wrap: wrap;
        padding: 10px 12px;
        margin-bottom: 12px;
        border: 1px solid var(--mat-sys-outline-variant);
        border-radius: 8px;
      }
      .bm-svc-label {
        font-size: 13px;
        opacity: 0.8;
      }
      .bm-svc-input {
        padding: 6px 8px;
        border: 1px solid var(--mat-sys-outline-variant);
        border-radius: 4px;
        background: transparent;
        color: inherit;
        min-width: 200px;
      }
      .bm-svc-ok {
        color: var(--bm-green);
        font-size: 13px;
      }
      .bm-svc-err {
        color: var(--bm-red);
        font-size: 13px;
      }
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
      .bm-ebpf-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-top: 8px; }
      @media (max-width: 900px) { .bm-ebpf-grid { grid-template-columns: 1fr; } }
      .bm-ebpf-panel { border: 1px solid var(--bm-border, #e0e0e0); border-radius: 6px; padding: 12px; overflow-x: auto; }
      .bm-ebpf-h { font-weight: 600; margin-bottom: 8px; }
      .bm-ebpf-tbl { width: 100%; border-collapse: collapse; font-size: 13px; }
      .bm-ebpf-tbl th, .bm-ebpf-tbl td { text-align: left; padding: 3px 8px; border-bottom: 1px solid var(--bm-border, #eee); white-space: nowrap; }
      .bm-ebpf-tbl th.bm-num, .bm-ebpf-tbl td.bm-num { text-align: right; }
      .bm-ebpf-panel .bm-mono { font-family: var(--bm-mono, monospace); }
      .bm-ebpf-h .bm-dim { opacity: 0.6; font-weight: 400; font-size: 12px; }
      .bm-ebpf-row { cursor: pointer; }
      .bm-ebpf-row:hover { background: var(--bm-hover, rgba(127,127,127,0.12)); }
      .bm-ebpf-row-sel, .bm-ebpf-row-sel:hover { background: rgba(76,175,80,0.18); }
      .bm-ebpf-filterbar { display: flex; align-items: center; gap: 8px; margin: 12px 0 4px; font-size: 13px; }
      .bm-ebpf-chip { display: inline-flex; align-items: center; gap: 6px; padding: 2px 4px 2px 10px;
        border-radius: 12px; background: rgba(76,175,80,0.18); font-family: var(--bm-mono, monospace); }
      .bm-ebpf-chip-x { border: none; background: transparent; cursor: pointer; font-size: 16px;
        line-height: 1; padding: 0 6px; color: inherit; opacity: 0.7; }
      .bm-ebpf-chip-x:hover { opacity: 1; }
      .bm-console-actions { display: flex; align-items: center; gap: 12px; margin-bottom: 10px; }
      .bm-rel-map { height: 460px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 8px 12px; margin-bottom: 16px; }
      .bm-rel-h { margin: 0 0 8px; font-size: 13px; opacity: 0.8; }
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
      .bm-proc-toolbar {
        display: flex;
        align-items: center;
        gap: 12px;
        margin-bottom: 12px;
        flex-wrap: wrap;
      }
      .bm-proc-filter {
        flex: 1 1 240px;
        min-width: 180px;
        padding: 7px 10px;
        border-radius: 6px;
        border: 1px solid color-mix(in srgb, var(--mat-sys-on-surface) 20%, transparent);
        background: transparent;
        color: inherit;
        font: inherit;
      }
      .bm-proc-idle {
        display: inline-flex;
        align-items: center;
        gap: 5px;
        font-size: 12.5px;
        opacity: 0.8;
        cursor: pointer;
      }
      .bm-proc-meta {
        margin-left: auto;
        opacity: 0.6;
        font-size: 13px;
        font-variant-numeric: tabular-nums;
      }
      .bm-proc .bm-num {
        text-align: right;
        font-variant-numeric: tabular-nums;
        white-space: nowrap;
      }
      .bm-proc th.bm-sortable {
        cursor: pointer;
        user-select: none;
        white-space: nowrap;
      }
      .bm-proc th.bm-sortable:hover { text-decoration: underline; }
      .bm-proc th.bm-sorted { font-weight: 700; }
      .bm-proc-cpu {
        position: relative;
        display: inline-flex;
        align-items: center;
        justify-content: flex-end;
        gap: 6px;
        min-width: 84px;
      }
      .bm-proc-cpu-bar {
        position: absolute;
        left: 0;
        top: 50%;
        transform: translateY(-50%);
        height: 14px;
        border-radius: 3px;
        opacity: 0.35;
      }
      .bm-proc-cpu-val {
        position: relative;
      }
      .bm-proc-cmd {
        font-family: var(--bm-mono, monospace);
        font-size: 12.5px;
        max-width: 520px;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .bm-proc-container,
      .bm-proc-connbadge {
        display: inline-block;
        margin-right: 6px;
        padding: 1px 6px;
        border-radius: 4px;
        font-size: 11px;
        background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent);
      }
      .bm-proc-detail {
        display: flex;
        gap: 32px;
        flex-wrap: wrap;
        padding: 4px 0;
      }
      .bm-proc-conns ul {
        list-style: none;
        padding: 0;
        margin: 6px 0 0;
        font-size: 13px;
        font-variant-numeric: tabular-nums;
      }
      .bm-proc-conns li {
        padding: 2px 0;
      }
      .bm-proc-connstate {
        opacity: 0.6;
        margin-left: 8px;
        font-size: 11px;
      }
      .bm-avail {
        margin-top: 16px;
      }
      .bm-avail-head {
        display: flex;
        align-items: center;
        gap: 12px;
      }
      .bm-avail-title {
        font-weight: 600;
      }
      .bm-avail-ranges {
        display: flex;
        gap: 2px;
      }
      .bm-svc-ranges {
        display: flex;
        gap: 2px;
        justify-content: flex-end;
        margin-bottom: 4px;
      }
      .bm-avail-range {
        min-width: 0;
        padding: 0 10px;
        line-height: 28px;
        opacity: 0.6;
      }
      .bm-avail-range--on {
        opacity: 1;
        font-weight: 700;
        text-decoration: underline;
      }
      .bm-avail-ok {
        margin-left: auto;
        font-variant-numeric: tabular-nums;
        font-weight: 700;
      }
      .bm-avail-bar {
        display: flex;
        height: 20px;
        border-radius: 4px;
        overflow: hidden;
        margin-top: 8px;
        background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent);
      }
      .bm-avail-seg {
        height: 100%;
      }
      .bm-avail-legend {
        list-style: none;
        padding: 0;
        margin: 8px 0 0;
        display: flex;
        flex-wrap: wrap;
        gap: 14px;
        font-size: 13px;
        font-variant-numeric: tabular-nums;
      }
      .bm-avail-legend li {
        display: flex;
        align-items: center;
        gap: 6px;
      }
      .bm-avail-dot {
        width: 10px;
        height: 10px;
        border-radius: 2px;
        display: inline-block;
      }
      .bm-avail-changes {
        opacity: 0.6;
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
      .bm-flag--soft {
        font-size: 10px;
        padding: 1px 6px;
        border-radius: 999px;
        background: color-mix(in srgb, var(--bm-gold) 22%, transparent);
        opacity: 1;
      }
      .bm-flag--flap {
        font-size: 10px;
        padding: 1px 6px;
        border-radius: 999px;
        background: color-mix(in srgb, var(--bm-red) 22%, transparent);
        opacity: 1;
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
  /** The x-axis window (epoch ms) the service chart is currently showing, so
   * a picked range (esp. 365d) is reflected on the axis even when the data
   * only covers the last few days. */
  serviceChartWindow = signal<{ start: number; end: number } | null>(null);
  serviceHistory = signal<ServiceHistoryPoint[]>([]);
  /** Block J4 management shell — for kicking its lazy load on tab open. */
  management = viewChild(HostManagementComponent);

  /** Block J1 process list (lazy-loaded when the Processes tab opens). */
  processes = signal<Process[]>([]);
  // eBPF tab: on-demand 'what' behind the latency heatmaps.
  ebpf = signal<EbpfDetail | null>(null);
  ebpfLoading = signal(false);
  ebpfLoaded = signal(false);
  /** Click-to-filter: the process (comm) both eBPF tables are narrowed to,
   * or null for "all". Set by clicking any row, cleared via the chip. */
  ebpfFilter = signal<string | null>(null);
  filteredTalkers = computed(() => {
    const f = this.ebpfFilter();
    const rows = this.ebpf()?.top_talkers ?? [];
    return f ? rows.filter((t) => t.comm === f) : rows;
  });
  filteredDiskIo = computed(() => {
    const f = this.ebpfFilter();
    const rows = this.ebpf()?.slowest_disk_io ?? [];
    return f ? rows.filter((d) => d.comm === f) : rows;
  });
  // Block J2: service control state.
  svcName = signal('');
  svcBusy = signal(false);
  svcMsg = signal<string | null>(null);
  svcErr = signal<string | null>(null);

  processFilter = signal('');
  processSort = signal<'cpu' | 'rss' | 'pid' | 'user'>('cpu');
  processSortDir = signal<'asc' | 'desc'>('desc');
  hideIdleProcesses = signal(true);
  processesLoading = signal(false);
  processesLoaded = signal(false);
  processCount = signal(0);
  sampleWindowMs = signal(0);
  expandedPid = signal<number | null>(null);

  /** Filter (command/user/pid) + client-side sort by the selected column. The
   * backend already returns CPU-desc; re-sorting lets the user flip to memory
   * or pid without a round-trip. */
  visibleProcesses = computed(() => {
    const f = this.processFilter().trim().toLowerCase();
    let list = this.processes();
    // Idle processes (no CPU AND no resident memory) are noise — hidden by
    // default, toggleable.
    if (this.hideIdleProcesses()) {
      list = list.filter((p) => p.cpu_percent > 0 || p.rss_kib > 0);
    }
    if (f) {
      list = list.filter(
        (p) =>
          p.command.toLowerCase().includes(f) ||
          p.comm.toLowerCase().includes(f) ||
          (p.user ?? '').toLowerCase().includes(f) ||
          String(p.pid).includes(f),
      );
    }
    const col = this.processSort();
    const dir = this.processSortDir() === 'asc' ? 1 : -1;
    return [...list].sort((a, b) => {
      let cmp: number;
      switch (col) {
        case 'pid':
          cmp = a.pid - b.pid;
          break;
        case 'rss':
          cmp = a.rss_kib - b.rss_kib;
          break;
        case 'user':
          cmp = (a.user || String(a.uid)).localeCompare(b.user || String(b.uid));
          break;
        default:
          cmp = a.cpu_percent - b.cpu_percent;
      }
      return cmp * dir;
    });
  });

  /** Click a Processes column header to sort by it. Re-clicking the active
   * column flips direction; switching columns picks a sensible default
   * (metrics high→low, identity columns low→high). */
  sortBy(col: 'cpu' | 'rss' | 'pid' | 'user'): void {
    if (this.processSort() === col) {
      this.processSortDir.update((d) => (d === 'asc' ? 'desc' : 'asc'));
    } else {
      this.processSort.set(col);
      this.processSortDir.set(col === 'pid' || col === 'user' ? 'asc' : 'desc');
    }
  }

  /** The ▲/▼ indicator for a sortable header (empty unless it is active). */
  sortArrow(col: 'cpu' | 'rss' | 'pid' | 'user'): string {
    if (this.processSort() !== col) return '';
    return this.processSortDir() === 'asc' ? ' ▲' : ' ▼';
  }

  /** Block H9 availability/SLA report for the expanded service. */
  availability = signal<Availability | null>(null);
  /** The one time window for the expanded service — drives BOTH its metric
   * chart and its availability/SLA report, so selecting a range actually
   * changes the chart (it used to be pinned to a fixed 1h `since`). */
  availabilityHours = signal(24);
  readonly availabilityRanges = [
    { label: '1h', hours: 1 },
    { label: '24h', hours: 24 },
    { label: '7d', hours: 168 },
    { label: '30d', hours: 720 },
    { label: '365d', hours: 8760 },
  ];
  overview = signal<FleetHost | null>(null);

  healthStatus = signal(agentHealthStatus({ enrollment_state: 'pending', last_seen_at: null }));
  private since = new Date(Date.now() - 3_600_000).toISOString();

  // Tabs in template order; a ?tab= query param (e.g. from the Overview
  // problems panel → Services) selects the initial tab.
  private readonly tabOrder = ['overview', 'services', 'inventory', 'checks', 'console', 'relationships', 'processes', 'runs', 'management'];
  initialTabIndex = 0;

  ngOnInit(): void {
    const id = this.route.snapshot.paramMap.get('id')!;
    const tab = (this.route.snapshot.queryParamMap.get('tab') || '').toLowerCase();
    const idx = this.tabOrder.indexOf(tab);
    if (idx >= 0) this.initialTabIndex = idx;

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
  /** Friendly agent-role label: a managed agent is a Duppy (satellite) or a
   * Selecta (proxy, fronts satellites); 'standalone' = un-enrolled/self-managed. */
  modeLabel(mode: string | null | undefined): string {
    return { satellite: 'Duppy', proxy: 'Selecta (proxy)', standalone: 'Standalone (unmanaged)' }[mode ?? ''] ?? (mode || '—');
  }

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
    this.loadServiceChart(svc);
    this.monitoringService.serviceHistory(agent.id, svc.name).subscribe((history) => this.serviceHistory.set(history));
    this.loadAvailability(svc);
  }

  /** (Re)load the expanded service's metric chart over the selected time
   * window (`availabilityHours`). Split out from selectService so a range
   * change reloads the chart, not just the availability report. */
  private loadServiceChart(svc: ServiceState): void {
    const agent = this.agent();
    if (!agent) return;
    this.serviceChartSeries.set([]);
    const spec = serviceMetricSpec(svc.name, svc.metric);
    if (!spec) return;
    const end = Date.now();
    const start = end - this.availabilityHours() * 3_600_000;
    this.serviceChartWindow.set({ start, end });
    const since = new Date(start).toISOString();
    forkJoin(spec.members.map((m) => this.agentService.metricSeries(agent.id, m, since))).subscribe((results) => {
      const series = results.map((res, i) => ({
        name: spec.mount ? `${spec.members[i]} ${spec.mount}` : spec.members[i],
        points: spec.mount ? res.points.filter((p) => p.labels['mount'] === spec.mount) : res.points,
      }));
      this.serviceChartSeries.set(series);
    });
  }

  /** Load the SLA report for the expanded service over the selected range. */
  private loadAvailability(svc: ServiceState): void {
    const agent = this.agent();
    if (!agent) return;
    this.availability.set(null);
    this.monitoringService
      .serviceAvailability(agent.id, svc.name, this.availabilityHours())
      .subscribe((report) => this.availability.set(report));
  }

  /** Pick the service time window — reloads the chart AND the availability
   * report so the whole detail view moves to the chosen range. */
  setServiceRange(hours: number): void {
    this.availabilityHours.set(hours);
    const svc = this.selectedService();
    if (svc) {
      this.loadServiceChart(svc);
      this.loadAvailability(svc);
    }
  }

  /** A CheckMK-style state colour for the availability bar segments. */
  availabilityColor(state: string): string {
    return { OK: BM_GREEN, WARN: BM_GOLD, CRIT: BM_RED, UNKNOWN: BM_UNKNOWN }[state] ?? BM_UNKNOWN;
  }

  /** Lazy-load a tab's live data the first time it is opened. */
  onTabChange(event: MatTabChangeEvent): void {
    if (event.tab.textLabel === 'Processes' && !this.processesLoaded() && !this.processesLoading()) {
      this.loadProcesses();
    }
    // Block J4: kick the management shell's default (Services) inner tab so it
    // loads without the user having to click an inner tab first.
    if (event.tab.textLabel === 'Management') {
      this.management()?.activate();
    }
    if (event.tab.textLabel === 'eBPF' && !this.ebpfLoaded() && !this.ebpfLoading()) {
      this.loadEbpf();
    }
  }

  /** Lazy-load the eBPF tab's context tables (top outbound connections +
   * slowest disk I/O) — the 'what' behind the latency heatmaps. Live
   * pass-through, so only fetched when the tab is first opened. */
  loadEbpf(): void {
    const agent = this.agent();
    if (!agent) return;
    this.ebpfLoading.set(true);
    this.agentService.ebpf(agent.id).subscribe({
      next: (res) => {
        this.ebpf.set(res);
        this.ebpfLoading.set(false);
        this.ebpfLoaded.set(true);
      },
      error: () => {
        this.ebpfLoading.set(false);
        this.ebpfLoaded.set(true);
      },
    });
  }

  /** Click a row → filter both eBPF tables by its process; click the same
   * process again to clear (toggle). */
  toggleEbpfFilter(comm: string): void {
    this.ebpfFilter.update((cur) => (cur === comm ? null : comm));
  }

  /** Block J2: restart/stop/start a systemd unit on this host. */
  controlService(action: 'restart' | 'stop' | 'start'): void {
    const agent = this.agent();
    const name = this.svcName().trim();
    if (!agent || !name || this.svcBusy()) return;
    this.svcBusy.set(true);
    this.svcMsg.set(null);
    this.svcErr.set(null);
    this.agentService.serviceControl(agent.id, name, action).subscribe({
      next: (res) => {
        this.svcBusy.set(false);
        const r = res.result as { changed?: boolean; msg?: string } | undefined;
        this.svcMsg.set(`${action} ${name}: ${r?.msg ?? 'ok'}${r?.changed === false ? ' (no change)' : ''}`);
      },
      error: (e) => {
        this.svcBusy.set(false);
        this.svcErr.set(e?.error?.detail ?? `${action} failed`);
      },
    });
  }

  /** Pop the console out into its own browser window. A unique window name per
   * click means several windows can be open at once. */
  openConsoleWindow(): void {
    const a = this.agent();
    if (!a) return;
    window.open(
      `${location.origin}/console/${a.id}`,
      `bm-console-${a.id}-${Date.now()}`,
      'width=1000,height=640,menubar=no,toolbar=no,location=no',
    );
  }

  loadProcesses(): void {
    const agent = this.agent();
    if (!agent) return;
    this.processesLoading.set(true);
    this.expandedPid.set(null);
    this.agentService.processes(agent.id).subscribe({
      next: (res) => {
        this.processes.set(res.processes);
        this.processCount.set(res.count);
        this.sampleWindowMs.set(res.sample_window_ms);
        this.processesLoading.set(false);
        this.processesLoaded.set(true);
      },
      error: () => {
        this.processes.set([]);
        this.processesLoading.set(false);
        this.processesLoaded.set(true);
      },
    });
  }

  toggleProcess(p: Process): void {
    this.expandedPid.set(this.expandedPid() === p.pid ? null : p.pid);
  }

  /** CPU bar width, clamped to 100% of the cell even when a multi-threaded
   * process reports >100% (100% == one core). */
  cpuBarWidth(p: Process): number {
    return Math.min(p.cpu_percent, 100);
  }

  cpuColor(p: Process): string {
    if (p.cpu_percent >= 80) return BM_RED;
    if (p.cpu_percent >= 40) return BM_GOLD;
    return BM_GREEN;
  }

  formatKiB(kib: number): string {
    if (kib >= 1048576) return (kib / 1048576).toFixed(1) + ' GiB';
    if (kib >= 1024) return (kib / 1024).toFixed(1) + ' MiB';
    return kib + ' KiB';
  }

  shortContainer(id: string): string {
    return id.slice(0, 12);
  }

  serviceBadge(svc: ServiceState) {
    return serviceStateBadge(svc.state);
  }

  historyBadge(h: ServiceHistoryPoint) {
    return serviceStateBadge(h.state);
  }

  /** Block P4: set a warn/crit threshold for THIS service on THIS host — a
   * host-scoped check_rule that beats the OU/global default (GPO precedence).
   * The metric + label (disk mount) are derived from the service so the
   * dialog opens pre-filled; the operator just sets warn/crit. */
  overrideThreshold(svc: ServiceState, event: Event): void {
    event.stopPropagation();
    const agent = this.agent();
    if (!agent) return;
    const spec = serviceMetricSpec(svc.name, svc.metric);
    const ref = this.dialog.open(ThresholdDialogComponent, {
      width: '460px',
      data: {
        hostName: agent.name,
        serviceName: svc.name,
        metric: spec?.members[0] ?? svc.metric ?? '',
        labelValue: spec?.mount ?? null,
      },
    });
    ref.afterClosed().subscribe((input) => {
      if (!input) return;
      this.monitoringService.createCheckRule(input).subscribe(() => this.reloadServices(svc.agent_id));
    });
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
