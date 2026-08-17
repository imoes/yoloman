import { Component, OnInit, computed, inject, signal, viewChild } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { ScopeVarsEditorComponent } from '../../shared/components/scope-vars-dialog/scope-vars-editor.component';
import { ProvisionDbDialogComponent } from './provision-db-dialog.component';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { FormsModule } from '@angular/forms';
import { ConfigCategory, categorizeConfigPath, groupByCategory } from '../../shared/config-categories';
import { formatBytes, formatMetricValue, serviceMetricSpec, thresholdContext } from '../../shared/format.util';
import { DatePipe, DecimalPipe } from '@angular/common';
import { forkJoin } from 'rxjs';
import { MatTabsModule, MatTabChangeEvent } from '@angular/material/tabs';
import { MatCardModule } from '@angular/material/card';
import { MatButtonToggleModule } from '@angular/material/button-toggle';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatDialog } from '@angular/material/dialog';
import { AgentService } from '../../core/services/agent.service';
import { CheckService } from '../../core/services/check.service';
import { CheckCatalogEntry } from '../../core/models/check.model';
import { SearchService } from '../../core/services/search.service';
import { MassAssignFacets } from '../../core/models/search.model';
import { RelationshipService } from '../../core/services/relationship.service';
import { RunService } from '../../core/services/run.service';
import { MonitoringService } from '../../core/services/monitoring.service';
import { HostGroupService } from '../../core/services/host-group.service';
import { OrchestrationService } from '../../core/services/orchestration.service';
import { Agent, ConfigResource, ConfigTemplate, DirectiveSpec, EbpfDetail, EbpfL7Event, LatestMetric, MetricPoint, ObservedResource, ObservedState, Process, StateGeneration, StatePlan, StateResourceChange } from '../../core/models/agent.model';
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
import { ProcessHistoryChartComponent } from './process-history-chart.component';
import { HostChecksComponent } from './host-checks.component';
import { HostConsoleComponent } from './host-console.component';
import { TopologyComponent } from '../topology/topology.component';
import { HostManagementComponent } from './management/host-management.component';
import { HostResourcesComponent } from './host-resources.component';
import { DeploymentEdgesComponent } from '../../shared/deployment-edges/deployment-edges.component';
import { KubernetesDeployComponent } from './kubernetes-deploy.component';
import { StandaloneOverviewComponent } from '../../standalone/standalone-overview.component';
import { ResourceNodeComponent } from '../../shared/resource-node/resource-node.component';
import { ParamFormComponent } from '../../shared/param-form/param-form.component';
import { ParamSchema } from '../../shared/param-form/param-form.types';
import { DesiredStateReportComponent, ConfigDesiredResource } from '../../shared/components/desired-state-report/desired-state-report.component';
import { EffectiveThresholdsComponent } from './effective-thresholds.component';
import { CompiledHostState } from '../../core/models/orchestration.model';
import { agentHealthStatus, availabilityColor, runStatusBadge, serviceStateBadge } from '../../shared/status.util';
import { HostConfigScopeService } from './host-config-scope.service';
import { ServiceGraphsDialogComponent, ServiceGraphsDialogData } from './service-graphs-dialog.component';

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
    StandaloneOverviewComponent,
    ResourceNodeComponent,
    ParamFormComponent,
    HostChecksComponent,
    HostConsoleComponent,
    TopologyComponent,
    HostManagementComponent,
    HostResourcesComponent,
    ScopeVarsEditorComponent,
    DeploymentEdgesComponent,
    KubernetesDeployComponent,
    MetricChartComponent,
    MetricGaugeComponent,
    TimeRangePickerComponent,
    PerfOMeterComponent,
    LatencyHeatmapComponent,
    ProcessHistoryChartComponent,
    DesiredStateReportComponent,
    EffectiveThresholdsComponent,
    FormsModule,
  ],
  template: `
    @if (agent(); as agent) {
      <div class="bm-page">
        <div class="bm-header-row">
          <h1>{{ agent.name }}</h1>
          <app-status-badge [status]="healthStatus()" [label]="agent.enrollment_state" />
        </div>

        <mat-tab-group class="bm-host-tabs" [selectedIndex]="initialTabIndex" (selectedTabChange)="onTabChange($event)">
          <mat-tab label="Overview"><ng-template matTabContent>
            <div class="bm-tab-content">
              <!-- Cockpit view (same component as the standalone console): live
                   gauges + filterable services grid + alerts, from this agent's
                   metrics. -->
              <app-standalone-overview [agentId]="agent.id" [hostName]="agent.name" />
              @if (overview(); as ov) {
                @if (ov.parent_name) {
                  <p class="bm-parent-note">
                    Behind proxy <a [routerLink]="['/hosts', ov.parent_agent_id]">{{ ov.parent_name }}</a>
                  </p>
                }
              }
            </div>
          </ng-template></mat-tab>

          <mat-tab label="Services"><ng-template matTabContent>
            <div class="bm-tab-content">
              <div class="bm-svc-toolbar">
                <button mat-stroked-button (click)="pollNow()" [disabled]="polling()"
                        title="Poll this host now instead of waiting for the next cycle">
                  <mat-icon>refresh</mat-icon> {{ polling() ? 'Polling…' : 'Poll now' }}
                </button>
                @if (pollMsg()) { <span class="bm-poll-msg">{{ pollMsg() }}</span> }
              </div>
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
                        <td class="bm-col-summary">
                          <div>{{ svc.output || '—' }}</div>
                          @if (serviceDetail(svc); as d) {
                            <div class="bm-svc-abs" title="absolute figures behind the percentage">{{ d }}</div>
                          }
                          @if (thresholdOf(svc); as t) {
                            <div class="bm-svc-thresh" title="the rule this service is graded against">{{ t }}</div>
                          }
                        </td>
                        <td class="bm-col-age">{{ timeAgo(svc.last_state_change) }}</td>
                        <td class="bm-col-age">{{ timeAgo(svc.last_checked) }}</td>
                        <td class="bm-col-pom">
                          @if (serviceIsPct(svc) && svc.value !== null) {
                            <app-perf-o-meter [value]="svc.value" [warn]="pomWarn(svc)" [crit]="pomCrit(svc)" />
                          } @else if (svc.value !== null) {
                            <span class="bm-svc-value">{{ svcValue(svc) }}</span>
                          }
                        </td>
                        <td class="bm-actions">
                          <button mat-icon-button (click)="pollService(svc, $event)" [disabled]="polling()"
                            title="Poll now — re-collect this host's metrics and checks">
                            <mat-icon [class.bm-spin]="pollingService() === svc.name">{{ pollingService() === svc.name ? 'sync' : 'refresh' }}</mat-icon>
                          </button>
                          <!-- Icon, not a label: it sits beside the poll icon in a row
                               already crowded with three text buttons. multiline_chart
                               (several lines) says "all the graphs", which is the point. -->
                          <button mat-icon-button (click)="openGraphs(svc, $event)"
                            title="Open graphs — every metric behind this check, not just the one it grades">
                            <mat-icon>multiline_chart</mat-icon>
                          </button>
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
                                        <span class="bm-history-value">{{ formatValue(selectedService()?.metric ?? '', h.value) }}</span>
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
          </ng-template></mat-tab>

          <mat-tab label="Inventory"><ng-template matTabContent>
            <div class="bm-tab-content">
              <app-host-inventory [agent]="agent" />
              <dl class="bm-facts">
                <dt>Address</dt>
                <dd>{{ agent.address || '—' }}</dd>
                <dt>Mode</dt>
                <dd>{{ modeLabel(agent.mode) }}</dd>
                <dt>Enrollment state</dt>
                <dd>{{ agent.enrollment_state }}</dd>
                <dt>Agent version</dt>
                <dd>{{ agent.agent_version || 'unknown' }}</dd>
                <dt>Last seen</dt>
                <dd>{{ agent.last_seen_at ? (agent.last_seen_at | date: 'medium') : 'never' }}</dd>
              </dl>

              <!-- P3b: editable classification — the same searchable facets the
                   fleet omnibox filters on (crit:/site:/tag:), assigned here per
                   host (bulk assignment is on the search result view). -->
              <div class="bm-classify">
                <div class="bm-classify-h">Classification</div>
                <div class="bm-classify-row">
                  <label>Criticality
                    <select [value]="agent.criticality || ''" (change)="setCriticality(agent, $any($event.target).value)" [disabled]="classBusy()">
                      <option value="">— unset —</option>
                      <option value="test">test</option>
                      <option value="stage">stage</option>
                      <option value="prod">prod</option>
                    </select>
                  </label>
                  <label>Site
                    <input type="text" placeholder="e.g. MUE-0" [value]="siteDraft() ?? (agent.site || '')"
                           (input)="siteDraft.set($any($event.target).value)" [disabled]="classBusy()" />
                    <button mat-button (click)="setSite(agent)" [disabled]="classBusy()">Save</button>
                  </label>
                </div>
                <div class="bm-classify-tags">
                  <span class="bm-classify-label">Tags</span>
                  @for (t of tagEntries(agent); track t.key) {
                    <span class="bm-tag-chip">{{ t.key }}@if (t.value) {: {{ t.value }}}
                      <button (click)="removeTag(agent, t.key)" [disabled]="classBusy()" title="remove">✕</button>
                    </span>
                  }
                  @if (!tagEntries(agent).length) { <span class="bm-dim">none</span> }
                  <span class="bm-tag-add">
                    <input type="text" placeholder="key" [value]="newTagKey()" (input)="newTagKey.set($any($event.target).value)" class="bm-tag-k" />
                    <input type="text" placeholder="value" [value]="newTagVal()" (input)="newTagVal.set($any($event.target).value)" class="bm-tag-v" />
                    <button mat-button (click)="addTag(agent)" [disabled]="classBusy() || !newTagKey().trim()">Add</button>
                  </span>
                </div>
                @if (classMsg()) { <span class="bm-classify-ok">{{ classMsg() }}</span> }
              </div>
            </div>
          </ng-template></mat-tab>

          <mat-tab label="Configuration"><ng-template matTabContent>
            <div class="bm-tab-content">
             <mat-tab-group class="bm-cfg-sub" (selectedTabChange)="onConfigSubTab($event)">
              <mat-tab label="Settings"><ng-template matTabContent>
              @if (observedLoading()) {
                <p class="bm-empty">Reading the host's configuration…</p>
              } @else if (observedError(); as err) {
                <p class="bm-empty">{{ err }}</p>
              } @else if (observed(); as obs) {
                <div class="bm-cfg-head">
                  <span class="bm-dim">The host as one document — {{ obs.config.length }} config file(s).
                    @if (observedCachedAt()) { <em>cached {{ observedCachedAt() | date: 'short' }} — Reload for live.</em> }
                  </span>
                  <button mat-stroked-button (click)="loadObserved(true)"><mat-icon>refresh</mat-icon> Reload</button>
                </div>
                @if (drift().managed.length) {
                  <div class="bm-drift-banner" [class.bm-drift-on]="drift().drift.length">
                    <mat-icon>{{ drift().drift.length ? 'sync_problem' : 'verified' }}</mat-icon>
                    @if (drift().drift.length) {
                      <span>{{ drift().drift.length }} of {{ drift().managed.length }} managed file(s) drifted from desired.</span>
                      <button mat-button (click)="driftOpen.set(!driftOpen())">{{ driftOpen() ? 'Hide' : 'Show' }} diff</button>
                      <button mat-flat-button color="primary" (click)="reapplyConfig()" [disabled]="driftBusy()">Re-sync to desired</button>
                    } @else {
                      <span>{{ drift().managed.length }} managed file(s), all in sync with desired.</span>
                    }
                  </div>
                  @if (drift().drift.length && driftOpen()) {
                    <div class="bm-drift-diff">
                      @for (c of drift().drift; track c.path) {
                        <div class="bm-drift-file">
                          <div class="bm-drift-fname" (click)="jumpToFile(c.path)" title="Open this file">
                            <mat-icon>description</mat-icon>{{ c.path }}
                            <span class="bm-drift-n">{{ driftRows(c.path).length }} change(s)</span>
                          </div>
                          <table class="bm-drift-tbl">
                            <thead><tr><th>Setting</th><th>Live (on host)</th><th></th><th>Desired</th></tr></thead>
                            <tbody>
                              @for (d of driftRows(c.path); track d.key) {
                                <tr>
                                  <td class="bm-mono">{{ d.key }}</td>
                                  <td class="bm-mono bm-drift-live">{{ d.live }}</td>
                                  <td class="bm-drift-arrow">→</td>
                                  <td class="bm-mono bm-drift-want">{{ d.desired }}</td>
                                </tr>
                              }
                            </tbody>
                          </table>
                        </div>
                      }
                    </div>
                  }
                }
                <input
                  class="bm-gpo-search"
                  type="search"
                  placeholder="Search settings…"
                  [ngModel]="gpoSearch()"
                  (ngModelChange)="gpoSearch.set($event)"
                />
                <!-- #5: add a config file the host doesn't have on disk yet, from
                     the codec catalog, then define it as policy (host/OU/group). -->
                <div class="bm-cfg-addfile">
                  <mat-icon class="bm-dim">note_add</mat-icon>
                  <input class="bm-kvin bm-addfile-in" list="bm-catalog-files"
                         placeholder="Add a config file the host doesn't have yet (e.g. /etc/apt/apt.conf)…"
                         [ngModel]="addFilePath()" (ngModelChange)="addFilePath.set($event)"
                         (keydown.enter)="addCatalogFile(addFilePath())" />
                  <datalist id="bm-catalog-files">
                    @for (f of catalogAddOptions(); track f) { <option [value]="f"></option> }
                  </datalist>
                  <button mat-stroked-button (click)="addCatalogFile(addFilePath())" [disabled]="!addFilePath().trim()">
                    <mat-icon>add</mat-icon> Add file
                  </button>
                </div>
                <div class="bm-gpo">
                  <!-- Miller column 1: categories -->
                  <div class="bm-gpo-col">
                    @for (c of gpoCategories(obs); track c.key) {
                      <div class="bm-gpo-cat" [class.bm-gpo-sel]="gpoActiveCat() === c.key" (click)="selectGpoCat(c.key)">
                        <mat-icon class="bm-gpo-cat-ic">{{ c.icon }}</mat-icon>{{ c.label }}
                        <span class="bm-gpo-count">{{ c.count }}</span>
                      </div>
                    }
                  </div>
                  <!-- Miller column 2: the category's items (thresholds / plans / files) -->
                  <div class="bm-gpo-col">
                    @for (it of gpoColItems(obs); track it.pane) {
                      <div class="bm-gpo-file" [class.bm-gpo-sel]="selectedPane() === it.pane" (click)="selectPane(it.pane)" [title]="it.title">
                        {{ it.label }}
                        @if (it.drift) { <span class="bm-dot-drift">●</span> }
                      </div>
                    } @empty {
                      <p class="bm-gpo-empty">Pick a category.</p>
                    }
                  </div>
                  <!-- Miller column 3: the selected pane -->
                  <div class="bm-gpo-main">
                    @if (selectedPane() === '::thresholds') {
                      <h3 class="bm-gpo-h">
                        Monitoring thresholds
                        <button mat-button (click)="startAddThr()" [disabled]="thrBusy()">
                          <mat-icon>add</mat-icon> Add threshold
                        </button>
                      </h3>
                      <!-- The table lists the thresholds the host INHERITS (compiled
                           desired state). A metric nobody has a rule for isn't in it
                           yet, so adding one needs its own affordance. -->
                      @if (addThr()) {
                        <mat-card class="bm-setting-dlg">
                          <strong>New threshold</strong>
                          <p class="bm-dim">Pick a check configured on this host, then set its warn/crit. Everything is documented — the selected check's description is shown on the right.</p>
                          <div class="bm-thr-miller">
                            <!-- Column 1: the checks/services configured on this host -->
                            <div class="bm-thr-col bm-thr-checks">
                              <input class="bm-kvin bm-thr-search" type="search" placeholder="filter checks…" [value]="thrSearch()" (input)="thrSearch.set($any($event.target).value)" />
                              @for (s of addThrServices(); track s.id) {
                                <div class="bm-thr-item" [class.sel]="newMetric() === s.metric && newService() === s.name" (click)="pickThrService(s)">
                                  <span class="bm-thr-dot" [style.background]="availabilityColor(s.state)"></span>
                                  <span class="bm-thr-item-name">{{ s.name }}</span>
                                  <span class="bm-thr-item-metric">{{ s.metric }}</span>
                                </div>
                              } @empty { <p class="bm-dim bm-thr-pad">No checks match.</p> }
                              <div class="bm-thr-other" [class.sel]="thrOther()" (click)="pickThrOther()">
                                <mat-icon>tune</mat-icon> Other metric…
                              </div>
                            </div>
                            <!-- Column 2: description + the threshold settings -->
                            <div class="bm-thr-col bm-thr-settings">
                              @if (newMetric() || thrOther()) {
                                <div class="bm-thr-desc">
                                  <div class="bm-thr-desc-h">{{ newService() || newMetric() || 'New check' }}</div>
                                  <pre class="bm-thr-desc-body">{{ thrDesc() }}</pre>
                                </div>
                                @if (thrOther()) {
                                  <label>Metric
                                    <input class="bm-kvin" list="bm-metric-options" [value]="newMetric()"
                                           (input)="onNewMetric($any($event.target).value)" placeholder="e.g. uptime_seconds" />
                                    <datalist id="bm-metric-options">
                                      @for (m of metricOptions(); track m) { <option [value]="m"></option> }
                                    </datalist>
                                  </label>
                                  <label>Service <input class="bm-kvin" [value]="newService()" (input)="newService.set($any($event.target).value)" placeholder="display name" /></label>
                                }
                                <div class="bm-thr-inputs">
                                  <label>Comparison
                                    <select class="bm-kvin" [value]="newComparison()" (change)="newComparison.set($any($event.target).value)">
                                      @for (c of comparisons; track c.v) { <option [value]="c.v">{{ c.label }}</option> }
                                    </select>
                                  </label>
                                  <label>Warn <input class="bm-kvin" [value]="newWarn()" (input)="newWarn.set($any($event.target).value)" /></label>
                                  <label>Crit <input class="bm-kvin" [value]="newCrit()" (input)="newCrit.set($any($event.target).value)" /></label>
                                </div>
                                <label class="bm-scope">Scope:
                                  <select [value]="applyScope()" (change)="applyScope.set($any($event.target).value)">
                                    <option value="host">this host</option>
                                    @if (agent.ou_id) { <option value="ou">OU (every host under it)</option> }
                                    @for (g of hostGroups(); track g.id) { <option [value]="'group:' + g.id">group {{ g.name }}</option> }
                                  </select>
                                </label>
                                <p class="bm-dim">A threshold set here always wins over a policy — it appears in the
                                  desired state with source <code>host:…</code> once the change is compiled.</p>
                                @if (thrError(); as te) { <p class="bm-cfg-err">{{ te }}</p> }
                              } @else {
                                <p class="bm-dim bm-thr-pad">Pick a check on the left to set its warn/crit — its description appears here.</p>
                              }
                              <div class="bm-rollback-actions">
                                <button mat-button (click)="addThr.set(false)" [disabled]="thrBusy()">Cancel</button>
                                <button mat-flat-button color="primary" (click)="createThr()" [disabled]="thrBusy() || !newMetric().trim()">Add</button>
                              </div>
                            </div>
                          </div>
                        </mat-card>
                      }
                      <table class="bm-gpo-settings">
                        <thead><tr><th>Service</th><th>Metric</th><th>Warn</th><th>Crit</th><th>Source</th></tr></thead>
                        <tbody>
                          @for (t of thresholds(); track t.metric) {
                            <tr (click)="openThr(t)" [class.bm-row-sel]="thrKey() === t.metric">
                              <td>{{ t.service_name ?? '—' }}</td><td class="bm-gpo-key">{{ t.metric }}</td>
                              <td>{{ t.warn ?? '—' }}</td><td>{{ t.crit ?? '—' }}</td>
                              <td><span class="bm-tag">{{ t.source ?? '—' }}</span></td>
                            </tr>
                          }
                        </tbody>
                      </table>
                      @if (thrKey(); as tk) {
                        <mat-card class="bm-setting-dlg">
                          <strong>{{ tk }}</strong>
                          <label class="bm-radio"><input type="radio" name="thrmode" [checked]="thrMode() === 'configured'" (change)="thrMode.set('configured')" /> Configured at this scope</label>
                          @if (thrMode() === 'configured') {
                            <div class="bm-thr-inputs">
                              <label>Warn <input class="bm-kvin" [value]="thrWarn()" (input)="thrWarn.set($any($event.target).value)" /></label>
                              <label>Crit <input class="bm-kvin" [value]="thrCrit()" (input)="thrCrit.set($any($event.target).value)" /></label>
                            </div>
                          }
                          <label class="bm-radio"><input type="radio" name="thrmode" [checked]="thrMode() === 'notconf'" (change)="thrMode.set('notconf')" /> Not configured at this scope (remove the rule)</label>
                          <label class="bm-scope">Scope:
                            <select [value]="applyScope()" (change)="applyScope.set($any($event.target).value)">
                              <option value="host">this host</option>
                              @if (agent.ou_id) { <option value="ou">OU (every host under it)</option> }
                              @for (g of hostGroups(); track g.id) { <option [value]="'group:' + g.id">group {{ g.name }}</option> }
                            </select>
                          </label>
                          @if (thrError(); as te) { <p class="bm-cfg-err">{{ te }}</p> }
                          <div class="bm-rollback-actions">
                            <button mat-button (click)="thrKey.set(null)" [disabled]="thrBusy()">Cancel</button>
                            <button mat-flat-button color="primary" (click)="applyThr()" [disabled]="thrBusy()">Apply</button>
                          </div>
                        </mat-card>
                      }
                    } @else if (selRes(obs); as r) {
                      <div class="bm-cfg-row">
                        <code class="bm-cfg-path">{{ r.path }}</code>
                        <span class="bm-tag">{{ r.format || 'raw' }}</span>
                        @if (isManaged(r.path)) {
                          @if (driftFor(r.path)) { <span class="bm-tag bm-tag-drift">drifted</span> } @else { <span class="bm-tag bm-tag-sync">managed ✓</span> }
                        }
                        @if (templateFor(r.path); as tpl) {
                          <button mat-button (click)="startTemplateEdit(r, tpl)"><mat-icon>dataset</mat-icon> Edit via template</button>
                        }
                      </div>
                      <div class="bm-cfg-viewtoggle">
                        <button type="button" class="bm-vt" [class.bm-vt-sel]="configView() === 'editor'" (click)="configView.set('editor')">Settings editor</button>
                        <button type="button" class="bm-vt" [class.bm-vt-sel]="configView() === 'resource'" (click)="configView.set('resource')">Resource view</button>
                        <span class="bm-dim bm-vt-note">Resource view = the generic config node (host-direct state + generations). The Settings editor keeps scope/policy, source, Removed and restart-after-apply.</span>
                      </div>
                      @if (configView() === 'resource') {
                        <app-resource-node kind="config" [name]="r.path" [agentId]="agent.id" />
                      } @else {
                      @if (tplEditPath() === r.path) {
                        <p class="bm-dim">Managed via template <strong>{{ tplName() }}</strong> — edit the values, the whole file is rendered from them.</p>
                        <app-param-form [params]="tplSchema()" [initial]="tplInitial()" [agentId]="agent.id"
                                        (valuesChange)="tplParamValues.set($event)" />
                        @if (tplError(); as te) { <p class="bm-cfg-err">{{ te }}</p> }
                        @if (tplRendered(); as rendered) {
                          <p class="bm-dim">Rendered file (would be written):</p>
                          <pre class="bm-cfg-values">{{ rendered }}</pre>
                        }
                        <label class="bm-scope">Apply to:
                          <select [value]="applyScope()" (change)="applyScope.set($any($event.target).value)">
                            <option value="host">this host</option>
                            @if (agent.ou_id) { <option value="ou">OU (every host under it)</option> }
                            @for (g of hostGroups(); track g.id) { <option [value]="'group:' + g.id">group {{ g.name }}</option> }
                          </select>
                        </label>
                        <div class="bm-rollback-actions">
                          <button mat-button (click)="cancelTemplateEdit()" [disabled]="tplBusy()">Cancel</button>
                          <button mat-button (click)="previewTemplate(r)" [disabled]="tplBusy()">Preview (render)</button>
                          <button mat-flat-button color="primary" (click)="applyTemplate(r)" [disabled]="tplBusy()">{{ applyScope() === 'host' ? 'Apply' : 'Apply to scope' }}</button>
                        </div>
                      } @else if (r.values) {
                        <table class="bm-gpo-settings">
                          <thead><tr><th>Setting</th><th>State</th><th>Value</th><th>Source</th></tr></thead>
                          <tbody>
                            @for (row of filteredSettingRows(r); track row.key) {
                              <tr (click)="openSetting(r, row)" [class.bm-row-sel]="settingKey() === row.key">
                                <td class="bm-gpo-key">{{ row.key }}</td>
                                <td [class.bm-dim]="row.state === 'Host based'">{{ row.state }}</td>
                                <td>
                                  @if (row.state === 'Configured') { {{ row.desired }} }
                                  @else if (row.state === 'Removed') { <s>{{ row.live || '—' }}</s> }
                                  @else { <span class="bm-dim">{{ row.live }}</span> }
                                </td>
                                <td>@if (row.source) { <span class="bm-tag" [class.bm-tag--baseline]="row.state === 'Host based'">{{ row.source }}</span> }</td>
                              </tr>
                            }
                          </tbody>
                        </table>
                        <div class="bm-cfg-addkey">
                          <input class="bm-kvin" placeholder="Add a setting key…"
                                 [ngModel]="newSettingKey()" (ngModelChange)="newSettingKey.set($event)"
                                 (keydown.enter)="addSettingKey(r)" />
                          <button mat-stroked-button (click)="addSettingKey(r)" [disabled]="!newSettingKey().trim()">Add</button>
                        </div>
                        @if (settingKey(); as sk) {
                          <mat-card class="bm-setting-dlg">
                            <strong>{{ sk }}</strong>
                            @if (directiveSpec(r); as ds) {
                              @if (ds.description) { <p class="bm-dim bm-directive-desc">{{ ds.description }}@if (ds.default) { <span> · default: <code>{{ ds.default }}</code></span> }</p> }
                            }
                            <label class="bm-radio"><input type="radio" name="setmode" [checked]="settingMode() === 'notconf'" (change)="settingMode.set('notconf')" /> Host based — no policy; the file keeps its own value</label>
                            <label class="bm-radio"><input type="radio" name="setmode" [checked]="settingMode() === 'configured'" (change)="settingMode.set('configured')" /> Configured</label>
                            @if (settingMode() === 'configured') {
                              @if (valueOptions(r); as opts) {
                                <select class="bm-kvin bm-setting-val" [ngModel]="settingValue()" (ngModelChange)="settingValue.set($event)">
                                  @for (o of opts; track o) { <option [value]="o">{{ o }}</option> }
                                </select>
                              } @else {
                                <input class="bm-kvin bm-setting-val" [value]="settingValue()" (input)="settingValue.set($any($event.target).value)" />
                              }
                            }
                            <label class="bm-radio"><input type="radio" name="setmode" [checked]="settingMode() === 'removed'" (change)="settingMode.set('removed')" /> Removed — enforce the key's absence in the file</label>
                            <label class="bm-scope">Scope:
                              <select [value]="applyScope()" (change)="applyScope.set($any($event.target).value)">
                                <option value="host">this host</option>
                                @if (agent.ou_id) { <option value="ou">OU (every host under it)</option> }
                                @for (g of hostGroups(); track g.id) { <option [value]="'group:' + g.id">group {{ g.name }}</option> }
                              </select>
                            </label>
                            @if (settingService(r.path); as svc) {
                              <label class="bm-scope bm-restart-svc">
                                <input type="checkbox" [checked]="restartAfterApply()" (change)="restartAfterApply.set($any($event.target).checked)" />
                                Restart <span class="bm-mono">{{ svc }}</span> after applying, so the change takes effect
                              </label>
                            }
                            @if (settingError(); as se) { <p class="bm-cfg-err">{{ se }}</p> }
                            <div class="bm-rollback-actions">
                              <button mat-button (click)="closeSetting()" [disabled]="settingBusy()">Cancel</button>
                              <button mat-flat-button color="primary" (click)="applySetting(r)" [disabled]="settingBusy()">
                                {{ (settingService(r.path) && restartAfterApply()) ? ('Apply & restart ' + settingService(r.path)) : 'Apply' }}
                              </button>
                            </div>
                          </mat-card>
                        }
                        @if (driftRows(r.path).length) {
                          <p class="bm-dim bm-drift-h">Drift — live vs desired:</p>
                          <table class="bm-diff">
                            <thead><tr><th>Key</th><th>Live</th><th>Desired</th></tr></thead>
                            <tbody>
                              @for (d of driftRows(r.path); track d.key) {
                                <tr><td>{{ d.key }}</td><td>{{ d.live }}</td><td>{{ d.desired }}</td></tr>
                              }
                            </tbody>
                          </table>
                        }
                      } @else if (r.raw) {
                        @if (editingPath() === r.path) {
                          <textarea class="bm-cfg-edit" rows="14" [value]="editText()" (input)="editText.set($any($event.target).value)"></textarea>
                          @if (editError(); as ee) { <p class="bm-cfg-err">{{ ee }}</p> }
                          @if (editPreview(); as ep) { <p class="bm-dim">{{ ep }}</p> }
                          <div class="bm-rollback-actions">
                            <button mat-button (click)="cancelEdit()" [disabled]="editBusy()">Cancel</button>
                            <button mat-button (click)="previewEdit(r)" [disabled]="editBusy()">Preview (dry-run)</button>
                            <button mat-flat-button color="primary" (click)="applyEdit(r)" [disabled]="editBusy()">Apply &amp; push</button>
                          </div>
                        } @else {
                          <pre class="bm-cfg-values">{{ r.raw }}</pre>
                          <button mat-button class="bm-cfg-editbtn" (click)="startEdit(r)"><mat-icon>edit</mat-icon> Edit (raw fallback)</button>
                        }
                      } @else if (r.sha256) {
                        <p class="bm-dim">opaque — sha256 {{ r.sha256.slice(0, 12) }}… ({{ r.size }} bytes)</p>
                      }
                      }
                    }
                  </div>
                </div>
                @if (!obs.config.length) { <p class="bm-empty">No config files discovered on this host.</p> }

                <!-- Block F2: generation history + rollback -->
                @if (generations().length) {
                  <h3 class="bm-cfg-gen-h">Generations</h3>
                  <table class="bm-cfg-gen">
                    <thead><tr><th>#</th><th>Applied</th><th>Hash</th><th>Resources</th><th></th></tr></thead>
                    <tbody>
                      @for (g of generations(); track g.number) {
                        <tr [class.bm-gen-current]="isCurrentGeneration(g.number)">
                          <td>{{ g.number }}</td>
                          <td>{{ g.applied_at | date: 'medium' }}</td>
                          <td><code>{{ g.hash.slice(0, 12) }}…</code></td>
                          <td>{{ g.resources }}</td>
                          <td>
                            @if (isCurrentGeneration(g.number)) {
                              <span class="bm-tag">current</span>
                            } @else {
                              <button mat-button (click)="previewRollback(g.number)" [disabled]="rollbackBusy()">Roll back to #{{ g.number }}…</button>
                            }
                          </td>
                        </tr>
                      }
                    </tbody>
                  </table>

                  @if (rollbackTarget() !== null) {
                    <mat-card class="bm-rollback">
                      <div class="bm-rollback-head">
                        <strong>Roll back to generation #{{ rollbackTarget() }}</strong>
                        <span class="bm-dim">— dry-run preview, nothing applied yet</span>
                      </div>
                      @if (rollbackBusy() && !rollbackPlan()) {
                        <p class="bm-empty">Computing the diff…</p>
                      } @else if (rollbackError(); as rerr) {
                        <p class="bm-cfg-err">{{ rerr }}</p>
                      } @else if (rollbackPlan(); as plan) {
                        @if (rollbackDiffRows().length) {
                          <table class="bm-diff">
                            <thead><tr><th>File</th><th>Action</th><th>Change</th></tr></thead>
                            <tbody>
                              @for (d of rollbackDiffRows(); track d.path + d.detail) {
                                <tr><td><code>{{ d.path }}</code></td><td>{{ d.action }}</td><td>{{ d.detail }}</td></tr>
                              }
                            </tbody>
                          </table>
                        } @else {
                          <p class="bm-dim">No changes — the host already matches generation #{{ rollbackTarget() }}.</p>
                        }
                      }
                      <div class="bm-rollback-actions">
                        <button mat-button (click)="cancelRollback()" [disabled]="rollbackBusy()">Cancel</button>
                        <button mat-flat-button color="warn" (click)="applyRollback()"
                                [disabled]="rollbackBusy() || !rollbackPlan() || !rollbackDiffRows().length">
                          Apply rollback
                        </button>
                      </div>
                    </mat-card>
                  }
                }
              } @else {
                <p class="bm-empty">Open this tab to read the host's configuration.</p>
              }
              </ng-template></mat-tab>
              <mat-tab label="Effective thresholds"><ng-template matTabContent>
                <app-effective-thresholds [agentId]="agent.id" />
              </ng-template></mat-tab>
              <mat-tab label="Desired state"><ng-template matTabContent>
                <div class="bm-ds-head">
                  <span class="bm-dim">The full compiled desired_state for this host — the GPO-merged result of the global, OU, group and host layers.</span>
                  <button mat-stroked-button (click)="loadDesiredJson()" [disabled]="desiredJsonLoading()"><mat-icon>refresh</mat-icon> Reload</button>
                </div>
                @if (desiredJsonLoading()) {
                  <p class="bm-empty">Compiling the desired state…</p>
                } @else if (desiredJsonError(); as e) {
                  <p class="bm-empty">{{ e }}</p>
                } @else if (desiredStateFull(); as ds) {
                  <app-desired-state-report [state]="ds" [config]="desiredConfig()" />
                }
              </ng-template></mat-tab>
             </mat-tab-group>
            </div>
          </ng-template></mat-tab>

          <mat-tab label="Management"><ng-template matTabContent>
            <div class="bm-tab-content">
              <app-host-management [agentId]="agent.id" [hostName]="agent.name" />
            </div>
          </ng-template></mat-tab>

          <mat-tab label="Checks"><ng-template matTabContent>
            <div class="bm-tab-content">
              <app-host-checks [agent]="agent" />
            </div>
          </ng-template></mat-tab>

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

          <mat-tab label="Relationships"><ng-template matTabContent>
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
          </ng-template></mat-tab>

          <mat-tab label="eBPF"><ng-template matTabContent>
            <div class="bm-tab-content">
              <p class="bm-dim">Kernel-level (eBPF) signals. The heatmaps show the latency <em>distribution</em>
                (buckets × time, color = event count); the tables below show <em>which</em> connections and
                disk I/O those events are — click a row to filter both tables by that process.</p>
              <div class="bm-ebpf-range">
                <span class="bm-dim">Zeitraum</span>
                <app-time-range-picker selectedRange="6h" (rangeChange)="ebpfSince.set($event)" />
              </div>
              <div class="bm-ebpf-grid">
                <app-latency-heatmap [agentId]="agent.id" metric="conn_latency_bucket"
                                     title="Outbound connect latency" [since]="ebpfSince()" />
                <app-latency-heatmap [agentId]="agent.id" metric="disk_io_latency_bucket"
                                     title="Disk I/O latency" [since]="ebpfSince()" />
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
                            <td class="bm-mono">{{ t.comm }}</td>
                            <td class="bm-mono">
                              @if (t.dst_host) {
                                {{ t.dst_host }}:{{ t.dst_port }}<span class="bm-dim bm-ebpf-ip"> · {{ t.dst_addr }}</span>
                              } @else {
                                {{ t.dst_addr }}:{{ t.dst_port }}
                              }
                            </td>
                            <td class="bm-num">{{ t.count }}</td>
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

              <!-- BCC-inspired signals: runqlat, oomkill, tcpretrans, killsnoop -->
              <div class="bm-ebpf-grid">
                <div class="bm-ebpf-panel">
                  <div class="bm-ebpf-h">Run-queue latency <span class="bm-dim">(scheduler wait, cumulative)</span></div>
                  @if (ebpf()?.runq_latency?.length) {
                    <div class="bm-runq">
                      @for (b of ebpf()!.runq_latency!; track $index) {
                        <div class="bm-runq-row">
                          <span class="bm-runq-le bm-mono">≤ {{ b.latency_us }} µs</span>
                          <span class="bm-runq-bar"><span class="bm-runq-fill" [style.width.%]="runqPct(b.count)"></span></span>
                          <span class="bm-runq-cnt bm-mono">{{ b.count }}</span>
                        </div>
                      }
                    </div>
                    <p class="bm-dim bm-runq-note">A tail into the millisecond buckets means tasks are waiting for CPU (saturation / contention).</p>
                  } @else { <p class="bm-empty">No run-queue latency data (sched tracing unavailable or just started).</p> }
                </div>

                <div class="bm-ebpf-panel">
                  <div class="bm-ebpf-h">OOM kills <span class="bm-dim">(kernel out-of-memory killer)</span></div>
                  @if (ebpf()?.oom_kills?.length) {
                    <table class="bm-table bm-ebpf-tbl">
                      <thead><tr><th>Process</th><th class="bm-num">PID</th></tr></thead>
                      <tbody>
                        @for (o of ebpf()!.oom_kills!; track $index) {
                          <tr><td class="bm-mono">{{ o.comm }}</td><td class="bm-num bm-mono">{{ o.pid }}</td></tr>
                        }
                      </tbody>
                    </table>
                  } @else { <p class="bm-empty">No OOM kills observed — nothing was killed for memory pressure.</p> }
                </div>

                <div class="bm-ebpf-panel">
                  <div class="bm-ebpf-h">TCP retransmits <span class="bm-dim">(network health)</span></div>
                  @if (ebpf()?.tcp_retransmits?.length) {
                    <table class="bm-table bm-ebpf-tbl">
                      <thead><tr><th>Process</th><th>Connection</th></tr></thead>
                      <tbody>
                        @for (r of ebpf()!.tcp_retransmits!; track $index) {
                          <tr>
                            <td class="bm-mono">{{ r.comm }}</td>
                            <td class="bm-mono">
                              {{ r.src_host || r.src_addr }}:{{ r.src_port }} → {{ r.dst_host || r.dst_addr }}:{{ r.dst_port }}
                              @if (r.src_host || r.dst_host) {
                                <div class="bm-dim bm-ebpf-ip">{{ r.src_addr }}:{{ r.src_port }} → {{ r.dst_addr }}:{{ r.dst_port }}</div>
                              }
                            </td>
                          </tr>
                        }
                      </tbody>
                    </table>
                  } @else { <p class="bm-empty">No retransmits observed — no packet loss on watched connections.</p> }
                </div>

                <div class="bm-ebpf-panel">
                  <div class="bm-ebpf-h">Signals <span class="bm-dim">(kill/term/abrt/segv — who killed what)</span></div>
                  @if (ebpf()?.signals?.length) {
                    <table class="bm-table bm-ebpf-tbl">
                      <thead><tr><th>Signal</th><th>Target</th><th>From</th></tr></thead>
                      <tbody>
                        @for (s of ebpf()!.signals!; track $index) {
                          <tr>
                            <td class="bm-mono">{{ s.signal }}</td>
                            <td class="bm-mono">{{ s.target_comm }} <span class="bm-dim">({{ s.target_pid }})</span></td>
                            <td class="bm-mono">{{ s.comm }} <span class="bm-dim">({{ s.pid }})</span></td>
                          </tr>
                        }
                      </tbody>
                    </table>
                  } @else { <p class="bm-empty">No notable signals observed.</p> }
                </div>

                <div class="bm-ebpf-panel bm-ebpf-panel--wide">
                  <div class="bm-ebpf-h">L7 requests <span class="bm-dim">(passive DNS / HTTP / SQL — payload-sniffed, no TLS)</span></div>
                  @if (ebpf()?.l7_events?.length) {
                    <table class="bm-table bm-ebpf-tbl">
                      <thead><tr><th>Proto</th><th>Request</th><th>Status</th><th class="bm-num">ms</th><th>Destination</th></tr></thead>
                      <tbody>
                        @for (l of l7EventsNewestFirst(); track $index) {
                          <tr>
                            <td><span class="bm-l7-proto bm-l7-proto--{{ l.protocol }}">{{ l.protocol }}</span></td>
                            <td class="bm-mono bm-l7-target" [title]="l.target || ''">
                              @if (l.method) { <span class="bm-dim">{{ l.method }}</span> }
                              {{ l.target }}
                              @if (l.answers?.length) { <span class="bm-dim">→ {{ l.answers!.join(', ') }}</span> }
                            </td>
                            <td><span class="bm-l7-status" [class.bm-l7-status--bad]="isL7Bad(l)">{{ l.status }}</span></td>
                            <td class="bm-num bm-mono">{{ l.duration_ms | number: '1.1-1' }}</td>
                            <td class="bm-mono">{{ l.dst_host || l.dst_addr }}@if (l.dst_port) {:{{ l.dst_port }}}</td>
                          </tr>
                        }
                      </tbody>
                    </table>
                  } @else { <p class="bm-empty">No L7 exchanges observed — no plaintext DNS/HTTP/DB traffic captured yet.</p> }
                </div>
              </div>
            </div>
          </ng-template></mat-tab>

          <mat-tab label="Processes"><ng-template matTabContent>
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
                          @if (p.service) {
                            <span class="bm-proc-service" title="systemd unit">⚙ {{ p.service }}</span>
                          }
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
                              <div class="bm-proc-history">
                                <strong>CPU &amp; memory history — {{ p.comm }} <span class="bm-dim">(by command, across restarts)</span></strong>
                                <app-process-history-chart [agentId]="agent.id" [comm]="p.comm" />
                              </div>
                              <dl class="bm-facts">
                                <dt>PPID</dt>
                                <dd>{{ p.ppid }}</dd>
                                <dt>Comm</dt>
                                <dd>{{ p.comm }}</dd>
                                @if (p.service) {
                                  <dt>Service</dt>
                                  <dd>{{ p.service }}</dd>
                                }
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
          </ng-template></mat-tab>

          <mat-tab label="Runs"><ng-template matTabContent>
            <div class="bm-tab-content">
              <div class="bm-run-filter">
                @for (t of runTypes; track t.key) {
                  <button class="bm-chip" [class.bm-chip-on]="runTypeFilter() === t.key" (click)="runTypeFilter.set(t.key)">{{ t.label }}</button>
                }
              </div>
              @if (hostRuns().length) {
                <table class="bm-table">
                  <thead>
                    <tr>
                      <th>Type</th>
                      <th>Name</th>
                      <th>Status</th>
                      <th>Dry run</th>
                      <th>When</th>
                    </tr>
                  </thead>
                  <tbody>
                    @for (run of hostRuns(); track run.type + run.id) {
                      <tr [routerLink]="run.link" [class.bm-row-link]="run.link">
                        <td><span class="bm-type bm-type-{{ run.type }}">{{ run.type }}</span></td>
                        <td>{{ run.name }}</td>
                        <td><app-status-badge [status]="badge(run.status)" [label]="run.status" /></td>
                        <td>{{ run.dryRun ? 'yes' : 'no' }}</td>
                        <td>{{ run.when | date: 'medium' }}</td>
                      </tr>
                    }
                  </tbody>
                </table>
              } @else {
                <p class="bm-empty">No runs against this host yet.</p>
              }
            </div>
          </ng-template></mat-tab>

          <!-- Block J4: Cockpit-like host management (Services/Logs/Accounts/
               Storage/Network). Each inner section pulls its live data lazily. -->
          <!-- Slice 2 (docs/ui-workspaces.md): everything on this host that answers the Resource
               protocol — config files, containers, Helm releases — each opened in the ONE generic
               inspector whose tabs are the verbs. -->
          <mat-tab label="Resources"><ng-template matTabContent>
            <div class="bm-tab-content">
              <app-host-resources [agentId]="agent.id" />
              <!-- Slice 4: the missing edge — what has been deployed TO this host. A Deployment is the
                   recorded apply() of an artefact onto a target, so this is the same audit trail the Deploy
                   workspace shows, filtered to this machine. -->
              <h3 class="bm-sec-h">Deployed here</h3>
              <app-deployment-edges [agentId]="agent.id" />
            </div>
          </ng-template></mat-tab>
          <mat-tab label="Kubernetes"><ng-template matTabContent>
            <div class="bm-tab-content">
              <app-kubernetes-deploy [agentId]="agent.id" />
            </div>
          </ng-template></mat-tab>
        </mat-tab-group>
      </div>
    }
  `,
  // One apply-scope per HOST PAGE, not per app: a scope silently carried from one host to another is
  // how an edit meant for one machine lands on a whole OU. Component-level providers give an instance
  // created and destroyed with this page, and that every pane split out of it can inject.
  providers: [HostConfigScopeService],
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
        /* Cap the width so the view isn't uncomfortably wide, centred — wide
           enough that the compact tab bar still fits on one row. */
        max-width: 1500px;
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
      .bm-ds-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 12px; }
      /* Compact the host tab labels so all of them fit on one row in the now
         full-width page — the user wants the page to widen, not the tab bar to
         wrap or paginate. Scoped to the outer group only. */
      :host ::ng-deep .bm-host-tabs > .mat-mdc-tab-header .mdc-tab { padding: 0 12px !important; min-width: 0 !important; }
      .bm-cfg-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 12px; }
      .bm-cfg-card { padding: 12px 14px; margin-bottom: 10px; }
      .bm-ebpf-range { display: flex; align-items: center; gap: 10px; margin: 0 0 10px; }
      .bm-cfg-row { display: flex; align-items: center; gap: 10px; }
      .bm-cfg-path { font-weight: 600; word-break: break-all; }
      .bm-cfg-viewtoggle { display: flex; align-items: center; gap: 6px; margin: 8px 0 12px; flex-wrap: wrap; }
      .bm-vt { font-size: 12px; padding: 3px 12px; border-radius: 999px; border: 1px solid var(--mat-sys-outline-variant); background: transparent; color: inherit; cursor: pointer; }
      .bm-vt-sel { background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent); border-color: var(--mat-sys-primary); }
      .bm-vt-note { flex: 1 1 220px; }
      .bm-cfg-values { margin: 8px 0 0; padding: 8px 10px; background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); border-radius: 6px; font-size: 12px; max-height: 320px; overflow: auto; white-space: pre-wrap; word-break: break-word; }
      .bm-cfg-err { color: var(--bm-crit, #c62828); margin: 8px 0 0; font-size: 13px; }
      .bm-cfg-editbtn { margin-top: 6px; }
      .bm-cfg-edit { width: 100%; box-sizing: border-box; margin-top: 8px; padding: 8px 10px; font-family: ui-monospace, monospace; font-size: 12px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); resize: vertical; }
      .bm-kvedit { width: 100%; border-collapse: collapse; margin-top: 8px; }
      .bm-kvedit th { text-align: left; font-size: 12px; opacity: 0.7; padding: 2px 6px; }
      .bm-kvedit td { padding: 2px 6px; vertical-align: middle; }
      .bm-kvedit td:nth-child(3) { width: 40px; }
      .bm-kvin { width: 100%; box-sizing: border-box; padding: 5px 8px; font-family: ui-monospace, monospace; font-size: 12px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 5px; background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
      .bm-cfg-editrow { display: flex; gap: 8px; flex-wrap: wrap; }
      .bm-tpl-field { margin: 8px 0; }
      .bm-tpl-field label { display: block; font-size: 12px; font-weight: 600; margin-bottom: 3px; }
      .bm-tpl-field label .bm-dim { font-weight: 400; }
      .bm-drift-banner { display: flex; align-items: center; gap: 10px; padding: 8px 12px; margin-bottom: 12px; border-radius: 8px; background: color-mix(in srgb, var(--bm-green, #2e7d32) 12%, transparent); font-size: 13px; }
      .bm-drift-banner.bm-drift-on { background: color-mix(in srgb, var(--bm-warn, #ef6c00) 16%, transparent); }
      .bm-drift-diff { margin: 0 0 12px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 8px 12px; }
      .bm-drift-file { margin: 6px 0; }
      .bm-drift-fname { display: flex; align-items: center; gap: 6px; font-family: ui-monospace, monospace; font-size: 12.5px; cursor: pointer; }
      .bm-drift-fname:hover { color: var(--mat-sys-primary); }
      .bm-drift-fname mat-icon { font-size: 16px; height: 16px; width: 16px; opacity: 0.7; }
      .bm-drift-n { opacity: 0.6; font-family: inherit; font-size: 11px; }
      .bm-drift-tbl { width: 100%; border-collapse: collapse; font-size: 12px; margin: 4px 0 2px; }
      .bm-drift-tbl th { text-align: left; font-size: 10.5px; opacity: 0.6; padding: 2px 10px; font-weight: 500; }
      .bm-drift-tbl td { padding: 2px 10px; border-top: 1px solid color-mix(in srgb, var(--mat-sys-outline-variant) 60%, transparent); }
      .bm-drift-live { color: var(--mat-sys-error, #c62828); }
      .bm-drift-want { color: var(--bm-green, #2e7d32); }
      .bm-drift-arrow { opacity: 0.5; }
      .bm-drift-banner mat-icon { flex: 0 0 auto; }
      .bm-tag-drift { background: color-mix(in srgb, var(--bm-warn, #ef6c00) 30%, transparent); }
      .bm-tag-sync { background: color-mix(in srgb, var(--bm-green, #2e7d32) 24%, transparent); }
      /* Baseline "Host" (the host's own value) muted; policy sources keep the accent tag. */
      .bm-tag--baseline { background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); opacity: 0.7; font-weight: 400; }
      .bm-drift-h { margin: 8px 0 2px; }
      .bm-scope { display: flex; align-items: center; gap: 6px; font-size: 12px; margin: 6px 0; opacity: 0.85; }
      .bm-gpo { display: flex; gap: 10px; align-items: stretch; }
      .bm-gpo-col { flex: 0 0 210px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 5px 0; font-size: 13px; max-height: 560px; overflow-y: auto; }
      .bm-gpo-search { display: block; width: 100%; max-width: 440px; margin: 2px 0 10px; padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font-size: 13px; box-sizing: border-box; }
      .bm-cfg-addfile { display: flex; align-items: center; gap: 8px; margin: 0 0 12px; max-width: 640px; }
      .bm-cfg-addfile .bm-addfile-in { flex: 1 1 auto; min-width: 0; }
      .bm-cfg-addkey { display: flex; gap: 8px; margin: 10px 0 0; }
      .bm-gpo-cat { padding: 7px 10px; cursor: pointer; display: flex; align-items: center; gap: 6px; border-left: 3px solid transparent; }
      .bm-gpo-cat:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
      .bm-gpo-cat .bm-gpo-count { margin-left: auto; font-size: 11px; opacity: 0.5; }
      .bm-gpo-cat-ic { font-size: 16px; width: 16px; height: 16px; opacity: 0.8; }
      .bm-gpo-file { padding: 6px 10px; cursor: pointer; border-left: 3px solid transparent; display: flex; align-items: center; gap: 6px; }
      .bm-gpo-file:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
      .bm-gpo-sel { border-left-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
      .bm-gpo-empty { opacity: 0.55; font-size: 12px; padding: 8px 10px; }
      .bm-gpo-main { flex: 1 1 auto; min-width: 0; }
      .bm-gpo-h { margin: 0 0 8px; }
      .bm-gpo-settings { width: 100%; border-collapse: collapse; font-size: 13px; }
      .bm-gpo-settings th, .bm-gpo-settings td { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
      .bm-gpo-settings tbody tr { cursor: pointer; }
      .bm-gpo-settings tbody tr:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
      .bm-gpo-key { font-family: ui-monospace, monospace; }
      .bm-row-sel { background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
      .bm-setting-dlg { margin-top: 12px; padding: 12px 14px; display: flex; flex-direction: column; gap: 6px; }
      .bm-radio { display: flex; align-items: center; gap: 8px; font-size: 13px; }
      .bm-setting-val { max-width: 420px; margin-left: 24px; }
      .bm-thr-inputs { display: flex; gap: 14px; margin-left: 24px; }
      .bm-thr-miller { display: grid; grid-template-columns: 260px 1fr; gap: 12px; min-height: 260px; }
      .bm-thr-col { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 6px; overflow-y: auto; max-height: 46vh; }
      .bm-thr-checks { display: flex; flex-direction: column; gap: 2px; }
      .bm-thr-search { margin: 2px 2px 6px; }
      .bm-thr-item { display: flex; align-items: center; gap: 7px; padding: 6px 8px; border-radius: 6px; cursor: pointer; font-size: 13px; }
      .bm-thr-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
      .bm-thr-item.sel { background: color-mix(in srgb, var(--mat-sys-primary) 14%, transparent); }
      .bm-thr-dot { width: 9px; height: 9px; border-radius: 50%; flex: 0 0 auto; }
      .bm-thr-item-name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .bm-thr-item-metric { font-family: ui-monospace, monospace; font-size: 10.5px; opacity: 0.55; }
      .bm-thr-other { display: flex; align-items: center; gap: 6px; padding: 6px 8px; border-radius: 6px; cursor: pointer; font-size: 12.5px; opacity: 0.8; border-top: 1px dashed var(--mat-sys-outline-variant); margin-top: 4px; }
      .bm-thr-other.sel { background: color-mix(in srgb, var(--mat-sys-primary) 14%, transparent); }
      .bm-thr-other mat-icon { font-size: 16px; height: 16px; width: 16px; }
      .bm-thr-settings { display: flex; flex-direction: column; gap: 8px; }
      .bm-thr-pad { padding: 10px; }
      .bm-thr-desc { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); border-radius: 6px; padding: 8px 10px; }
      .bm-thr-desc-h { font-weight: 600; font-size: 13px; margin-bottom: 3px; }
      .bm-thr-desc-body { margin: 0; font-size: 11.5px; opacity: 0.8; white-space: pre-wrap; line-height: 1.4; }
      .bm-thr-inputs label { display: flex; align-items: center; gap: 6px; font-size: 13px; }
      .bm-dot-drift { color: var(--bm-warn, #ef6c00); margin-left: 6px; }
      .bm-cfg-gen-h { margin: 20px 0 8px; }
      .bm-cfg-gen, .bm-diff { width: 100%; border-collapse: collapse; font-size: 13px; }
      .bm-cfg-gen th, .bm-cfg-gen td, .bm-diff th, .bm-diff td { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
      .bm-gen-current { background: color-mix(in srgb, var(--bm-green, #2e7d32) 8%, transparent); }
      .bm-rollback { margin-top: 12px; padding: 12px 14px; }
      .bm-rollback-head { margin-bottom: 8px; display: flex; gap: 8px; align-items: baseline; flex-wrap: wrap; }
      .bm-rollback-actions { display: flex; gap: 8px; justify-content: flex-end; margin-top: 10px; }
      .bm-ebpf-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-top: 8px; }
      @media (max-width: 900px) { .bm-ebpf-grid { grid-template-columns: 1fr; } }
      .bm-ebpf-panel { border: 1px solid var(--bm-border, #e0e0e0); border-radius: 6px; padding: 12px; overflow-x: auto; }
      .bm-ebpf-h { font-weight: 600; margin-bottom: 8px; }
      .bm-ebpf-tbl { width: 100%; border-collapse: collapse; font-size: 13px; }
      .bm-ebpf-ip { font-size: 11px; }
      .bm-ebpf-tbl th, .bm-ebpf-tbl td { text-align: left; padding: 3px 8px; border-bottom: 1px solid var(--bm-border, #eee); white-space: nowrap; }
      .bm-ebpf-tbl th.bm-num, .bm-ebpf-tbl td.bm-num { text-align: right; }
      .bm-ebpf-panel--wide { grid-column: 1 / -1; }
      .bm-l7-target { max-width: 480px; overflow: hidden; text-overflow: ellipsis; }
      .bm-l7-proto { display: inline-block; padding: 1px 6px; border-radius: 4px; font-size: 11px; text-transform: uppercase;
        background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent); }
      .bm-l7-proto--dns { background: color-mix(in srgb, var(--mat-sys-tertiary) 20%, transparent); }
      .bm-l7-proto--postgres, .bm-l7-proto--mysql { background: color-mix(in srgb, var(--mat-sys-secondary) 22%, transparent); }
      .bm-l7-status--bad { color: var(--mat-sys-error, #c62828); font-weight: 600; }
      .bm-ebpf-panel .bm-mono { font-family: var(--bm-mono, monospace); }
      .bm-ebpf-h .bm-dim { opacity: 0.6; font-weight: 400; font-size: 12px; }
      .bm-runq { display: flex; flex-direction: column; gap: 3px; }
      .bm-runq-row { display: grid; grid-template-columns: 72px 1fr 64px; align-items: center; gap: 8px; font-size: 12px; }
      .bm-runq-le { opacity: 0.75; text-align: right; }
      .bm-runq-bar { background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); border-radius: 3px; height: 12px; overflow: hidden; }
      .bm-runq-fill { display: block; height: 100%; background: var(--mat-sys-primary, #3f51b5); border-radius: 3px; }
      .bm-runq-cnt { text-align: right; opacity: 0.8; }
      .bm-runq-note { margin-top: 8px; font-size: 11.5px; }
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
      .bm-classify { margin-top: 16px; padding: 14px; border-radius: 8px; border: 1px solid var(--mat-sys-outline-variant); background: color-mix(in srgb, var(--mat-sys-primary) 5%, transparent); }
      .bm-classify-h { font-weight: 600; margin-bottom: 10px; }
      .bm-classify-row { display: flex; gap: 20px; flex-wrap: wrap; align-items: center; margin-bottom: 12px; }
      .bm-classify-row label, .bm-classify-tags { display: flex; align-items: center; gap: 8px; font-size: 13px; flex-wrap: wrap; }
      .bm-classify select, .bm-classify input { padding: 4px 8px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
      .bm-classify-label { font-weight: 500; opacity: 0.7; }
      .bm-tag-chip { display: inline-flex; align-items: center; gap: 6px; padding: 2px 8px; border-radius: 12px; font-size: 12px; background: color-mix(in srgb, var(--mat-sys-tertiary) 18%, transparent); }
      .bm-tag-chip button { border: 0; background: transparent; cursor: pointer; opacity: 0.6; padding: 0; }
      .bm-tag-add { display: inline-flex; gap: 6px; align-items: center; }
      .bm-tag-k { width: 90px; } .bm-tag-v { width: 110px; }
      .bm-classify-ok { color: var(--bm-green); font-size: 13px; }
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
      .bm-proc-history { flex-basis: 100%; width: 100%; margin-bottom: 8px; }
      .bm-proc-history strong { display: block; font-size: 13px; margin-bottom: 4px; opacity: 0.85; }
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
      .bm-proc-connbadge,
      .bm-proc-service {
        display: inline-block;
        margin-right: 6px;
        padding: 1px 6px;
        border-radius: 4px;
        font-size: 11px;
        background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent);
      }
      .bm-proc-service {
        background: color-mix(in srgb, var(--mat-sys-tertiary) 18%, transparent);
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
      .bm-svc-thresh {
        font-size: 12px;
        opacity: 0.55;
        font-variant-numeric: tabular-nums;
        margin-top: 2px;
      }
      /* Absolute figures: measured data, so a step brighter than the threshold
         rule beneath it — but still subordinate to the check's own summary. */
      .bm-svc-abs {
        font-size: 12px;
        opacity: 0.75;
        font-variant-numeric: tabular-nums;
        margin-top: 2px;
      }
      .bm-svc-toolbar {
        display: flex;
        align-items: center;
        gap: 12px;
        margin-bottom: 12px;
      }
      .bm-poll-msg {
        font-size: 12px;
        opacity: 0.7;
      }
      .bm-spin {
        animation: bm-spin 1s linear infinite;
      }
      @keyframes bm-spin {
        to {
          transform: rotate(360deg);
        }
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
      .bm-run-filter { display: flex; gap: 8px; margin-bottom: 12px; }
      .bm-chip { padding: 5px 14px; border-radius: 16px; border: 1px solid var(--mat-sys-outline-variant); background: transparent; color: inherit; cursor: pointer; font-size: 13px; }
      .bm-chip-on { background: var(--mat-sys-primary); color: var(--mat-sys-on-primary); border-color: transparent; }
      .bm-type { font-size: 11px; text-transform: uppercase; padding: 2px 7px; border-radius: 4px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
      .bm-type-plan { background: color-mix(in srgb, #1565c0 22%, transparent); }
      .bm-type-runbook { background: color-mix(in srgb, #6a1b9a 22%, transparent); }
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
  private http = inject(HttpClient);
  private agentService = inject(AgentService);
  private checkService = inject(CheckService);
  private thrCatalog = signal<CheckCatalogEntry[]>([]);
  private searchService = inject(SearchService);
  private relationshipService = inject(RelationshipService);
  private runService = inject(RunService);
  private monitoringService = inject(MonitoringService);
  private hostGroupService = inject(HostGroupService);
  private orchestration = inject(OrchestrationService);
  private dialog = inject(MatDialog);

  agent = signal<Agent | null>(null);
  selectedMetric = signal<string | null>(null);
  metricPoints = signal<MetricPoint[]>([]);
  chartSeries = signal<ChartSeries[]>([]);
  latestMetrics = signal<LatestMetric[]>([]);
  /** Latest sample per (metric, LABELS) series — the per-mount / per-core rows
   * that `latestMetrics` (DISTINCT ON metric) cannot express. Feeds the absolute
   * figures under a percentage summary: a "% used" tells nobody whether the
   * remaining 46 % is 400 GB or 400 MB. */
  seriesSnapshot = signal<LatestMetric[]>([]);
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
  /** Host Runs tab (unified): runbook executions against this host, merged
   * with plan runs into one host-scoped timeline. Deployments stay on the
   * fleet-wide Runs page — they are multi-host aggregates, not host-scoped. */
  runbookRuns = signal<{ id: string; runbook_name: string; status: string; dry_run: boolean; created_at: string }[]>([]);
  runTypeFilter = signal<'all' | 'plan' | 'runbook'>('all');
  readonly runTypes = [
    { key: 'all', label: 'All' },
    { key: 'plan', label: 'Plans' },
    { key: 'runbook', label: 'Runbooks' },
  ] as const;
  hostRuns = computed(() => {
    const rows: { id: string; type: 'plan' | 'runbook'; name: string; status: string; dryRun: boolean; when: string; link: string[] | null }[] = [
      ...this.runs().map((r) => ({ id: r.id, type: 'plan' as const, name: r.plan_name, status: r.status, dryRun: r.dry_run, when: r.started_at, link: ['/runs', r.id] })),
      ...this.runbookRuns().map((r) => ({ id: r.id, type: 'runbook' as const, name: r.runbook_name, status: r.status, dryRun: r.dry_run, when: r.created_at, link: null })),
    ];
    const t = this.runTypeFilter();
    const filtered = t === 'all' ? rows : rows.filter((r) => r.type === t);
    return filtered.sort((a, b) => (a.when < b.when ? 1 : -1));
  });
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
  // Largest run-queue-latency bucket count, for scaling the histogram bars.
  private runqMax = computed(() => {
    const h = this.ebpf()?.runq_latency ?? [];
    return h.reduce((m, b) => (b.count > m ? b.count : m), 0);
  });
  runqPct(count: number): number {
    const max = this.runqMax();
    return max > 0 ? Math.max(2, Math.round((count / max) * 100)) : 0;
  }
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
          (p.service ?? '').toLowerCase().includes(f) ||
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

  // Block F1 — server-as-a-document (Configuration tab), lazily loaded.
  observed = signal<ObservedState | null>(null);
  observedLoading = signal(false);
  observedError = signal<string | null>(null);
  observedCachedAt = signal<string | null>(null); // when the served cache was captured (null = just fetched live)
  // Block F2 — generation history + rollback (same tab).
  generations = signal<StateGeneration[]>([]);
  rollbackTarget = signal<number | null>(null); // generation being previewed
  rollbackPlan = signal<StatePlan | null>(null); // dry-run diff for that target
  rollbackBusy = signal(false);
  rollbackError = signal<string | null>(null);

  healthStatus = signal(agentHealthStatus({ enrollment_state: 'pending', last_seen_at: null }));
  private since = new Date(Date.now() - 3_600_000).toISOString();

  // Tabs in template order; a ?tab= query param (e.g. from the Overview
  // problems panel → Services) selects the initial tab.
  // Order MUST match the <mat-tab> order in the template (index → ?tab= deep link).
  // Grouped by theme: status (overview/services/inventory) → config & manage
  // (configuration + management adjacent) → checks/diagnostics → ops.
  private readonly tabOrder = ['overview', 'services', 'inventory', 'configuration', 'management', 'checks', 'console', 'relationships', 'ebpf', 'processes', 'runs', 'resources', 'kubernetes'];
  initialTabIndex = 0;

  ngOnInit(): void {
    const id = this.route.snapshot.paramMap.get('id')!;
    const tab = (this.route.snapshot.queryParamMap.get('tab') || '').toLowerCase();
    const idx = this.tabOrder.indexOf(tab);
    if (idx >= 0) this.initialTabIndex = idx;

    this.agentService.get(id).subscribe((agent) => {
      this.agent.set(agent);
      this.healthStatus.set(agentHealthStatus(agent));
      // Deep-linked initial tab fires no (selectedTabChange) event, so kick the
      // lazy Configuration loads here when it's the landing tab.
      if (this.tabOrder[this.initialTabIndex] === 'configuration') {
        this.loadConfigCatalogs();
        this.loadObserved();
      }
    });

    this.loadLatest(id);

    this.relationshipService.list(id).subscribe((edges) => this.edges.set(edges));
    this.runService.list({ agent_id: id }).subscribe((runs) => this.runs.set(runs));
    this.runService.runbookRuns(100, id).subscribe((res) => this.runbookRuns.set(res.runs ?? []));
    this.reloadServices(id);
    this.monitoringService.fleetHosts().subscribe((hosts) => this.overview.set(hosts.find((h) => h.id === id) ?? null));
  }

  /** Both latest-data shapes in one go: the per-METRIC list for the raw table,
   * and the per-SERIES snapshot for the per-mount/per-core figures. */
  private loadLatest(agentId: string): void {
    this.agentService.metricsLatest(agentId).subscribe((res) => this.latestMetrics.set(res.metrics));
    this.agentService.metricsSnapshot(agentId).subscribe((res) => this.seriesSnapshot.set(res.metrics));
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

  polling = signal(false);
  pollMsg = signal('');
  pollingService = signal<string | null>(null);

  /** Poll now scoped to one service row. Checks run together on the agent, so
   * this triggers the same full poll but shows a spinner on that row and
   * refreshes the table afterwards. */
  pollService(svc: ServiceState, event: Event): void {
    event.stopPropagation();
    const agent = this.agent();
    if (!agent || this.polling()) return;
    this.polling.set(true);
    this.pollingService.set(svc.name);
    this.agentService.pollNow(agent.id).subscribe({
      next: () => {
        this.polling.set(false);
        this.pollingService.set(null);
        this.reloadServices(agent.id);
        this.loadLatest(agent.id);
      },
      error: () => { this.polling.set(false); this.pollingService.set(null); },
    });
  }

  /** Poll this host immediately (metrics + state + assigned checks), then
   * refresh the services table — instead of waiting for the next poll tick. */
  pollNow(): void {
    const agent = this.agent();
    if (!agent || this.polling()) return;
    this.polling.set(true);
    this.pollMsg.set('');
    this.agentService.pollNow(agent.id).subscribe({
      next: (r) => {
        this.polling.set(false);
        this.pollMsg.set(r.errors?.length ? `polled with errors: ${r.errors.join('; ')}` : `polled · ${r.metrics_written} metrics`);
        this.reloadServices(agent.id);
        this.loadLatest(agent.id);
      },
      error: () => { this.polling.set(false); this.pollMsg.set('poll failed'); },
    });
  }

  /** Expand/collapse a service row inline (CheckMK-style, Block H3) —
   * expanding loads its chart + state history via selectService. */
  /** Friendly agent-role label: a managed agent is a Duppy (satellite) or a
   * Selecta (proxy, fronts satellites); 'standalone' = un-enrolled/self-managed. */
  modeLabel(mode: string | null | undefined): string {
    // 'cluster' (C1): a host whose services are computed from its nodes rather than
    // polled — nothing ever contacts it, which is why it has no address.
    return { satellite: 'Duppy', proxy: 'Selecta (proxy)', standalone: 'Standalone (unmanaged)',
      cluster: 'Cluster (aggregated from nodes)' }[mode ?? ''] ?? (mode || '—');
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
    // CPU load is a float value (shown as a number, not a % Perf-O-Meter) even
    // though its per-core series metric ends in _pct.
    if (svc.name === 'CPU load' || svc.metric === 'cpu_pct') return false;
    const spec = serviceMetricSpec(svc.name, svc.metric);
    return !!spec && spec.members[0].endsWith('_pct');
  }

  /** Open every graph behind a service, in a popup. The inline expansion plots
   * only the metric the check grades; investigating usually needs the rest
   * (a disk's bytes, memory's six series, IOPS per device/VM). stopPropagation
   * so the row doesn't also toggle its inline expansion underneath the dialog. */
  openGraphs(svc: ServiceState, event: Event): void {
    event.stopPropagation();
    const agent = this.agent();
    if (!agent) return;
    this.dialog.open(ServiceGraphsDialogComponent, {
      data: {
        agentId: agent.id,
        hostName: agent.name,
        serviceName: svc.name,
        serviceMetric: svc.metric,
        available: this.seriesSnapshot(),
        hours: this.availabilityHours(),
      } satisfies ServiceGraphsDialogData,
      autoFocus: false,
      // Width belongs here, not in the component's styles: a min-width on
      // mat-dialog-content does not widen the dialog container around it, so the
      // charts were drawn into an overflow and clipped mid-legend.
      width: '92vw',
      maxWidth: '1200px',
    });
  }

  /** F-17: "warn ≥ 80 %, crit ≥ 90 %" — the rule the service is graded against. */
  thresholdOf(svc: ServiceState): string {
    return thresholdContext(svc);
  }

  /** The absolute figures behind a percentage/load summary — "46 % free" says
   * nothing about whether that is 400 GB or 400 MB, and a load average says
   * nothing about which core is pinned. Read off the per-SERIES snapshot, so a
   * disk row reports ITS mount rather than an arbitrary one.
   *   Disk /var → "10.4 GiB of 20.4 GiB used · 9.5 GiB free"
   *   Memory    → "2.4 GiB of 3.9 GiB used · 1.4 GiB available"
   *   CPU load  → "12 % busy · core 1: 17 %, core 0: 8 %"  (2 cores)
   *             → "12 % busy · busiest core 7: 46 % · 32 cores"  (many cores)
   * Empty string when the host hasn't reported the underlying series (older
   * agent, or a check without telemetry) — the caller then renders nothing. */
  serviceDetail(svc: ServiceState): string {
    const snap = this.seriesSnapshot();
    const val = (metric: string, label?: string, value?: string): number | null => {
      const hit = snap.find((m) => m.metric === metric && (label === undefined || m.labels[label] === value));
      return hit ? hit.value : null;
    };
    const usage = (used: number, total: number, freeWord: string, free: number) =>
      `${formatBytes(used)} of ${formatBytes(total)} used · ${formatBytes(Math.max(0, free))} ${freeWord}`;

    if (svc.name.startsWith('Disk /')) {
      const mount = svc.name.slice('Disk '.length);
      const used = val('disk_used_bytes', 'mount', mount);
      const total = val('disk_total_bytes', 'mount', mount);
      if (used === null || total === null) return '';
      return usage(used, total, 'free', total - used);
    }
    if (svc.name === 'Memory' || svc.metric === 'mem_used_pct') {
      const used = val('mem_used_bytes');
      const total = val('mem_total_bytes');
      if (used === null || total === null) return '';
      // MemAvailable is the kernel's own estimate of what a new workload can
      // actually get (reclaimable cache included) — a truer "free" than total-used.
      const avail = val('mem_available_bytes');
      return usage(used, total, avail !== null ? 'available' : 'free', avail ?? total - used);
    }
    if (svc.name === 'CPU load' || svc.metric === 'cpu_pct') {
      const cores = snap
        .filter((m) => m.metric === 'cpu_core_pct')
        .sort((a, b) => Number(a.labels['core']) - Number(b.labels['core']));
      if (!cores.length) return '';
      const busy = cores.reduce((sum, c) => sum + c.value, 0) / cores.length;
      const head = `${busy.toFixed(0)} % busy`;
      // 32-core hosts exist in this fleet, so only a small set is listed in full;
      // beyond that the one number that matters is the hottest core (a single
      // pinned core is invisible in both the average and the load figure).
      if (cores.length <= 8) {
        return `${head} · ${cores.map((c) => `core ${c.labels['core']}: ${c.value.toFixed(0)} %`).join(', ')}`;
      }
      const hottest = cores.reduce((a, b) => (b.value > a.value ? b : a));
      return `${head} · busiest core ${hottest.labels['core']}: ${hottest.value.toFixed(0)} % · ${cores.length} cores`;
    }
    return '';
  }

  /** F-17: real warn threshold for the perf-o-meter, falling back to the
   * historical 80/90 pair when the service has no rule thresholds. */
  pomWarn(svc: ServiceState): number {
    return svc.warn_threshold ?? 80;
  }
  pomCrit(svc: ServiceState): number {
    return svc.crit_threshold ?? 90;
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

    // Per-label fan-out (CPU cores): fetch one metric, split its points into one
    // series per distinct label value ("core 0", "core 1", …). Falls back to the
    // aggregate series when the per-core metric has no data.
    if (spec.perLabel) {
      const key = spec.perLabel;
      this.agentService.metricSeries(agent.id, spec.members[0], since).subscribe((res) => {
        const byLabel = new Map<string, typeof res.points>();
        for (const p of res.points) {
          const v = String(p.labels?.[key] ?? '');
          if (!byLabel.has(v)) byLabel.set(v, []);
          byLabel.get(v)!.push(p);
        }
        if (byLabel.size) {
          const series = [...byLabel.entries()]
            .sort((a, b) => Number(a[0]) - Number(b[0]) || a[0].localeCompare(b[0]))
            .map(([v, points]) => ({ name: `${key} ${v}`, points }));
          this.serviceChartSeries.set(series);
        } else if (spec.fallback) {
          this.agentService.metricSeries(agent.id, spec.fallback, since)
            .subscribe((r2) => this.serviceChartSeries.set([{ name: spec.fallback!, points: r2.points }]));
        }
      });
      return;
    }

    forkJoin(spec.members.map((m) => this.agentService.metricSeries(agent.id, m, since))).subscribe((results) => {
      const series = results.map((res, i) => {
        // Pin one label value where the spec asks for it: a mount (disk) or an
        // iface (interface throughput). Both share their metric across many rows.
        const key = spec.mount ? 'mount' : spec.labelKey;
        const val = spec.mount ?? spec.labelValue;
        const points = key ? res.points.filter((p) => p.labels[key] === val) : res.points;
        const suffix = val ? ` ${val}` : '';
        return { name: `${spec.members[i]}${suffix}`, points };
      });
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
  /** The shared state→colour mapping, exposed for the template. A field pointing at the imported
   * function rather than a re-implementation: one definition, and the three call sites in the views
   * stay untouched, which is what makes this a move and not a rewrite. */
  availabilityColor = availabilityColor;

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
    if (event.tab.textLabel === 'Configuration') {
      this.loadConfigCatalogs();
      if (this.observed() === null && !this.observedLoading()) this.loadObserved();
    }
  }

  /** The two host-independent config catalogs (directives ~1.9 MB, codecs ~0.6 MB)
   * are ONLY needed by the Configuration tab's editors, so they are loaded lazily
   * on first open rather than on every host page load — the single biggest chunk
   * of the Host Overview's initial payload. Guarded so it fetches at most once. */
  private configCatalogsLoaded = false;
  private loadConfigCatalogs(): void {
    if (this.configCatalogsLoaded) return;
    this.configCatalogsLoaded = true;
    // ADMX: the per-directive value catalog, so a config setting's editor can
    // offer the real allowed values (enum) instead of guessing a yes/no family.
    this.agentService.configDirectives().subscribe({
      next: (r) => this.directiveCatalog.set(r.directives || {}),
      error: () => { this.configCatalogsLoaded = false; },
    });
    // Host-independent codec catalog: every config file we know how to parse.
    // Lets the operator add a file this host doesn't have yet (e.g. apt.conf)
    // and define it as policy — parity with the OU policy editor (#5).
    this.agentService.configCodecs().subscribe({
      next: (r) => {
        const seen = new Set<string>();
        const files: { path: string; format: string; separator: string }[] = [];
        for (const e of r.entries ?? []) {
          const path = (e.paths ?? []).find((p) => p && !p.includes('*')) ?? e.pattern;
          if (!path || path.includes('*') || seen.has(path)) continue;
          seen.add(path);
          files.push({ path, format: e.codec === 'none' ? 'keyvalue' : e.codec, separator: e.separator ?? '' });
        }
        this.codecCatalog.set(files);
      },
      error: () => {},
    });
  }

  /** Inner Configuration tabs: lazy-load the desired_state JSON on first open. */
  onConfigSubTab(event: MatTabChangeEvent): void {
    if (event.tab.textLabel === 'Desired state' && this.desiredStateFull() === null && !this.desiredJsonLoading()) {
      this.loadDesiredJson();
    }
  }

  /** Block F1 — the server-as-a-document read. Live agent pull (slow-ish), so
   * loaded lazily when the Configuration tab is first opened. */
  loadObserved(refresh = false): void {
    const agent = this.agent();
    if (!agent) return;
    this.loadVarsCount();
    this.observedLoading.set(true);
    this.observedError.set(null);
    this.rollbackTarget.set(null);
    this.rollbackPlan.set(null);
    // Default open = the Postgres cache (instant); Reload = live re-fetch.
    this.agentService.observedState(agent.id, refresh).subscribe({
      next: (res) => {
        this.observed.set(res.observed);
        this.observedCachedAt.set((res as { cached_at?: string }).cached_at ?? null);
        this.observedLoading.set(false);
      },
      error: (e) => {
        this.observedError.set(e?.error?.detail ?? 'could not read observed state');
        this.observedLoading.set(false);
      },
    });
    // Generation history (Block F2) — independent of the observed read.
    this.agentService.stateGenerations(agent.id).subscribe({
      next: (res) => this.generations.set(res.generations ?? []),
      error: () => this.generations.set([]),
    });
    // Class-B template catalog (Block K2), for path↔template binding.
    if (!this.templates().length) {
      this.agentService.configTemplates().subscribe({
        next: (res) => this.templates.set(res.templates ?? []),
        error: () => this.templates.set([]),
      });
    }
    // Drift: desired (Bossman DB) vs observed (Block K3).
    this.agentService.configDrift(agent.id).subscribe({
      next: (res) => this.drift.set(res),
      error: () => this.drift.set({ managed: [], drift: [] }),
    });
    // Thresholds + applied plans for the GPO categories (Block G).
    this.loadDesiredMonitoring();
    // Host groups for the apply-to-group scope (Block K4). All groups are
    // offered — targeting a group the host isn't in still creates the policy +
    // converges that group's members (agents.groups can lag the membership
    // table, so we don't filter by it).
    this.scope.loadGroups();
  }

  // Block K3: drift = the recorded desired config re-planned against the host.
  drift = signal<{
    managed: string[]; drift: StateResourceChange[]; sources?: Record<string, string>;
    desired?: Record<string, Record<string, unknown>>; key_sources?: Record<string, Record<string, string>>;
  }>({ managed: [], drift: [], sources: {} });
  driftBusy = signal(false);

  // Count of host_vars for the Configuration ▸ Variables category badge. Loaded
  // when the Configuration tab opens and refreshed after an in-place save.
  varsReloadTick = signal(0);
  openProvisionDb(agent: { id: string; name: string }): void {
    const ref = this.dialog.open(ProvisionDbDialogComponent, {
      width: '640px', data: { consumerAgentId: agent.id, consumerName: agent.name },
    });
    ref.afterClosed().subscribe((ok) => {
      if (ok) { this.varsReloadTick.update((t) => t + 1); this.loadVarsCount(); }
    });
  }

  varsCount = signal(0);
  private loadVarsCount(): void {
    const a = this.agent();
    if (!a) return;
    this.http.get<{ vars?: Record<string, unknown> }>(
      `${environment.apiUrl}/scope-vars?scope_type=host&agent_id=${a.id}`,
    ).subscribe({
      next: (r) => this.varsCount.set(Object.keys(r?.vars ?? {}).length),
      error: () => this.varsCount.set(0),
    });
  }
  onVarsSaved(): void { this.loadVarsCount(); }

  // ---- Block G: GPO-style settings editor (gpedit model: category tree left,
  // settings list right, per-setting Not configured / Configured / Removed) ----
  selectedPane = signal<string>('::thresholds');
  selectPane(p: string): void {
    this.selectedPane.set(p);
    this.closeSetting();
    this.cancelEdit();
    this.cancelTemplateEdit();
    this.thrKey.set(null);
    this.configView.set('editor');   // each file opens in the scope-aware editor
  }

  // Per config file: the scope-aware Settings editor (default) or the generic
  // config ResourceNode ("Resource view", host-direct state + generations). The
  // node COMPLEMENTS the editor — it doesn't replace scope/policy/removed/restart.
  configView = signal<'editor' | 'resource'>('editor');

  // gpedit Miller columns: category (col 1) → its items (col 2) → pane (col 3).
  // Monitoring + Policies are pseudo-categories; the rest are config-file
  // categories from categoryGroups().
  gpoActiveCat = signal<string>('::mon');
  selectGpoCat(key: string): void { this.gpoActiveCat.set(key); }

  // Drift diff: the banner can expand to show every drifted file + its
  // key-level live→desired changes, and jump to a file in the Miller view.
  driftOpen = signal(false);
  jumpToFile(path: string): void {
    this.gpoSearch.set('');
    this.gpoActiveCat.set(categorizeConfigPath(path).key);
    this.selectPane(path);
  }

  gpoCategories(obs: ObservedState): { key: string; label: string; icon: string; count: number }[] {
    const cats: { key: string; label: string; icon: string; count: number }[] = [
      // Policies and Variables MOVED to the Management tab's Miller list (management/host-policies,
      // management/host-variables). They are not config files, and this list's categories are
      // config-file categories — keeping them here made "category" mean two things. Removed rather
      // than left in place: a second copy in the same product is how one of the two starts to rot.
      { key: '::mon', label: 'Monitoring', icon: 'speed', count: this.thresholds().length },
    ];
    for (const g of this.categoryGroups(obs)) {
      cats.push({ key: g.cat.key, label: g.cat.label, icon: g.cat.icon, count: g.files.length });
    }
    return cats;
  }

  gpoColItems(obs: ObservedState): { pane: string; label: string; title: string; drift: boolean }[] {
    const cat = this.gpoActiveCat();
    if (cat === '::mon') return [{ pane: '::thresholds', label: 'Thresholds', title: 'Monitoring thresholds', drift: false }];

    const grp = this.categoryGroups(obs).find((g) => g.cat.key === cat);
    return (grp?.files ?? []).map((f) => ({ pane: f.path, label: this.baseName(f.path), title: f.path, drift: !!this.driftFor(f.path) }));
  }
  baseName(p: string): string {
    return p.split('/').pop() || p;
  }
  /** gpedit live search: filters the category tree by file path OR any
   * setting key inside the file (searching "PermitRoot" surfaces sshd_config
   * under Security even though the filename doesn't match). */
  gpoSearch = signal('');
  categoryGroups(obs: ObservedState): { cat: ConfigCategory; files: ObservedResource[] }[] {
    const q = this.gpoSearch().trim().toLowerCase();
    const all = this.allConfig(obs);
    const files = !q
      ? all
      : all.filter(
          (r) =>
            r.path.toLowerCase().includes(q) ||
            this.flatKeys(r).some((k) => k.toLowerCase().includes(q)),
        );
    return groupByCategory(files);
  }
  private flatKeys(r: ObservedResource): string[] {
    const flat = r.format === 'keyvalue' ? Object.entries(r.values ?? {}) : this.flatten(r.values ?? {});
    return flat.map(([k]) => k);
  }
  selRes(obs: ObservedState): ObservedResource | null {
    return this.allConfig(obs).find((r) => r.path === this.selectedPane()) ?? null;
  }

  /** The settings list narrowed by the live search: when the query matched
   * the file by a KEY (not its path), only the matching keys are shown, so
   * searching "PermitRoot" jumps straight to the setting. */
  filteredSettingRows(r: ObservedResource): { key: string; state: string; desired: string; live: string; source: string | null }[] {
    const rows = this.settingRows(r);
    const q = this.gpoSearch().trim().toLowerCase();
    if (!q || r.path.toLowerCase().includes(q)) return rows;
    const hit = rows.filter((row) => row.key.toLowerCase().includes(q));
    return hit.length ? hit : rows;
  }

  /** Setting rows for a codec'd file: the union of live keys and desired keys.
   * State per key: Configured (managed with a value), Removed (managed null =
   * enforced absent), Not configured (live only, unmanaged). */
  settingRows(r: ObservedResource): { key: string; state: string; desired: string; live: string; source: string | null }[] {
    const desired = this.drift().desired?.[r.path] ?? {};
    const srcs = this.drift().key_sources?.[r.path] ?? {};
    const flat = (v: Record<string, unknown> | undefined) =>
      r.format === 'keyvalue' ? Object.entries(v ?? {}) : this.flatten(v ?? {});
    const live = new Map(flat(r.values));
    const des = new Map(flat(desired));
    // Union in the file's known ADMX directives so every settable key shows as
    // a row (configured or not) — like the Group Policy Editor lists all known
    // settings, not just the ones already present in the file.
    const specs = this.specsForPath(r.path);
    const keys = [...new Set([...live.keys(), ...des.keys(), ...Object.keys(specs)])].sort();
    return keys.map((key) => {
      const managed = des.has(key);
      const dv = des.get(key);
      return {
        key,
        state: managed ? (dv === null ? 'Removed' : 'Configured') : 'Host based',
        desired: dv === null || dv === undefined ? '' : this.scalarStr(dv),
        // Unmanaged key: the host's live value, or the directive default as a hint.
        live: live.has(key) ? this.scalarStr(live.get(key)) : this.scalarStr(specs[key]?.default ?? ''),
        // A managed key is sourced from the GPO scope it won at (Host/Group/OU/
        // Default *policy*); an unmanaged key is just the host's own baseline
        // value → "Host". So policy-set settings read as a policy, and the
        // host's own values read as "Host".
        source: managed ? this.sourceLabel(srcs[key]) : 'Host',
      };
    });
  }

  /** Human GPO-scope label for a config key's winning source. */
  sourceLabel(scope: string | null | undefined): string {
    switch (scope) {
      case 'host': return 'Host policy';
      case 'group': return 'Group policy';
      case 'ou': return 'OU policy';
      case 'global': return 'Default policy';
      default: return scope || 'Policy';
    }
  }
  private flatten(v: Record<string, unknown>, prefix = ''): [string, unknown][] {
    const out: [string, unknown][] = [];
    for (const [k, val] of Object.entries(v)) {
      const key = prefix ? `${prefix}.${k}` : k;
      if (val !== null && typeof val === 'object' && !Array.isArray(val)) out.push(...this.flatten(val as Record<string, unknown>, key));
      else out.push([key, val]);
    }
    return out;
  }
  private unflatten(key: string, value: unknown, deep: boolean): Record<string, unknown> {
    if (!deep || !key.includes('.')) return { [key]: value };
    const parts = key.split('.');
    const root: Record<string, unknown> = {};
    let node = root;
    for (const p of parts.slice(0, -1)) {
      const n: Record<string, unknown> = {};
      node[p] = n;
      node = n;
    }
    node[parts[parts.length - 1]] = value;
    return root;
  }

  // Per-setting dialog (gpedit's Not configured / Enabled / Disabled).
  settingKey = signal<string | null>(null);
  settingMode = signal<'notconf' | 'configured' | 'removed'>('configured');
  settingValue = signal('');
  settingBusy = signal(false);
  settingError = signal<string | null>(null);
  openSetting(r: ObservedResource, row: { key: string; state: string; desired: string; live: string }): void {
    this.settingKey.set(row.key);
    this.settingMode.set(row.state === 'Removed' ? 'removed' : row.state === 'Configured' ? 'configured' : 'notconf');
    this.settingValue.set(row.desired || row.live || '');
    this.settingError.set(null);
  }
  closeSetting(): void {
    this.settingKey.set(null);
    this.settingError.set(null);
  }
  /** ADMX per-directive value catalog ({file: {directive: spec}}), loaded once. */
  directiveCatalog = signal<Record<string, Record<string, DirectiveSpec>>>({});

  /** ADMX directive specs for a file. config_directives.json is keyed by FULL
   * path (e.g. /etc/apt/apt.conf.d/…); basename is a legacy fallback. Keying by
   * basename alone (the old bug) missed every full-path entry, so settings fell
   * back to a generic text input instead of the enum/bool/int field the catalog
   * defines — the same bug that was fixed in the OU policy editor. */
  private specsForPath(path: string): Record<string, DirectiveSpec> {
    const cat = this.directiveCatalog();
    const base = (path || '').split('/').pop() || '';
    return cat[path] ?? cat[base] ?? {};
  }

  /** The mined spec for the setting currently being edited on this resource.
   * Null if unmined. */
  directiveSpec(r: ObservedResource): DirectiveSpec | null {
    const key = this.settingKey();
    if (!key) return null;
    return this.specsForPath(r.path)[key] ?? null;
  }

  /** Possible values as a listbox. Prefers the ADMX catalog (enum's real
   * allowed values / bool), so e.g. PermitRootLogin offers all four values —
   * not just the yes/no family guessed from the current value. Falls back to
   * the family heuristic when the directive isn't in the catalog, and to a
   * free-text input (null) otherwise. */
  valueOptions(r: ObservedResource): string[] | null {
    const spec = this.directiveSpec(r);
    if (spec) {
      if (spec.type === 'enum' && spec.values?.length) {
        const val = this.settingValue();
        return spec.values.includes(val) || !val ? spec.values : [val, ...spec.values];
      }
      if (spec.type === 'bool') return ['yes', 'no'];
      if (spec.type === 'int' || spec.type === 'string' || spec.type === 'list') return null;
    }
    const key = this.settingKey();
    if (!key) return null;
    const row = this.settingRows(r).find((x) => x.key === key);
    const cur = (row?.desired || row?.live || '').trim().toLowerCase();
    const families = [['yes', 'no'], ['true', 'false'], ['on', 'off'], ['enabled', 'disabled']];
    const fam = families.find((f) => f.includes(cur));
    if (!fam) return null;
    const val = this.settingValue();
    return fam.includes(val) ? fam : [val, ...fam].filter((v, i, a) => v !== '' && a.indexOf(v) === i);
  }
  /** The systemd service that owns a config path, from the observed-state
   * discovery (service -> config_paths). Lets the Apply button also restart the
   * right unit so the change takes effect. Null when no service claims it. */
  settingService(path: string): string | null {
    const svcs = (this.observed()?.services as { service: string; config_paths?: string[] }[] | undefined) ?? [];
    const hit = svcs.find((s) => (s.config_paths ?? []).includes(path));
    return hit ? hit.service.replace(/@$/, '') : null; // strip template unit suffix (getty@)
  }
  restartAfterApply = signal(true);

  // #5 — reach a config file the host doesn't have yet. The codec catalog lists
  // every known file; picking one injects a synthetic (empty) resource so the
  // existing settings editor + Apply path can define it as desired config at
  // host/OU/group scope (stateApply doesn't require the file to pre-exist).
  codecCatalog = signal<{ path: string; format: string; separator: string }[]>([]);
  extraConfigFiles = signal<ObservedResource[]>([]);
  addFilePath = signal('');

  /** Observed files ∪ catalog files the operator added (dedup by path). */
  private allConfig(obs: ObservedState): ObservedResource[] {
    const extra = this.extraConfigFiles().filter((e) => !obs.config.some((c) => c.path === e.path));
    return [...obs.config, ...extra];
  }

  /** Catalog paths not already shown, for the "add a file" datalist. */
  catalogAddOptions(): string[] {
    const have = new Set<string>([
      ...(this.observed()?.config ?? []).map((c) => c.path),
      ...this.extraConfigFiles().map((c) => c.path),
    ]);
    return this.codecCatalog().map((e) => e.path).filter((p) => !have.has(p));
  }

  addCatalogFile(path: string): void {
    const p = (path || '').trim();
    if (!p) return;
    this.addFilePath.set('');
    const obs = this.observed();
    const present = (obs?.config ?? []).some((c) => c.path === p) || this.extraConfigFiles().some((c) => c.path === p);
    if (!present) {
      const cat = this.codecCatalog().find((e) => e.path === p);
      const res = { path: p, format: cat?.format || 'keyvalue', separator: cat?.separator || '=', values: {} } as ObservedResource;
      this.extraConfigFiles.update((xs) => [...xs, res]);
    }
    if (obs) {
      const grp = this.categoryGroups(obs).find((g) => g.files.some((f) => f.path === p));
      if (grp) this.gpoActiveCat.set(grp.cat.key);
    }
    this.selectPane(p);
  }

  // Add an arbitrary setting key to the selected file (for files with no mined
  // directives, or a key the catalog doesn't list) — mirrors the OU editor.
  newSettingKey = signal('');
  addSettingKey(r: ObservedResource): void {
    const k = this.newSettingKey().trim();
    if (!k) return;
    this.newSettingKey.set('');
    this.openSetting(r, { key: k, state: 'Host based', desired: '', live: '' });
  }

  applySetting(r: ObservedResource): void {
    const agent = this.agent();
    const key = this.settingKey();
    if (!agent || !key) return;
    const mode = this.settingMode();
    this.settingBusy.set(true);
    this.settingError.set(null);
    const svc = this.settingService(r.path);
    const restart = !!svc && this.restartAfterApply() && mode !== 'notconf';
    const finish = () => { this.settingBusy.set(false); this.closeSetting(); this.loadObserved(); };
    const done = () => {
      // After the config is applied, restart the owning service so the change
      // takes effect (the user's "apply + restart" ask) — best-effort: a
      // restart failure surfaces but the config change itself already landed.
      if (restart) {
        this.agentService.serviceControl(agent.id, svc!, 'restart').subscribe({
          next: finish,
          error: (e: { error?: { detail?: string } }) => {
            this.settingError.set(`Config applied, but restarting ${svc} failed: ${e?.error?.detail ?? 'error'}`);
            this.settingBusy.set(false);
            this.loadObserved();
          },
        });
      } else {
        finish();
      }
    };
    const fail = (e: { error?: { detail?: string } }) => { this.settingError.set(e?.error?.detail ?? 'failed'); this.settingBusy.set(false); };
    if (mode === 'notconf') {
      // Stop managing at the chosen scope; the live file is untouched.
      const scope = this.scopeArg();
      this.agentService.unsetDesired(agent.id, { path: r.path, key, ou_id: scope?.ouId, host_group_id: scope?.groupId }).subscribe({ next: done, error: fail });
      return;
    }
    const value = mode === 'removed' ? null : this.settingValue();
    const values = this.unflatten(key, value, r.format !== 'keyvalue');
    const resource: ConfigResource = { type: 'config', path: r.path, format: r.format, separator: r.separator, values };
    this.agentService.stateApply(agent.id, [resource], false, this.scopeArg()).subscribe({ next: done, error: fail });
  }

  // Thresholds category (check_rules as GPO settings) + applied plans.
  thresholds = signal<{ metric: string; service_name?: string; warn?: number | null; crit?: number | null; comparison?: string; source?: string }[]>([]);
  appliedPlans = signal<{ name: string; version: number | null; type: string; source: string }[]>([]);
  thrKey = signal<string | null>(null);
  thrMode = signal<'configured' | 'notconf'>('configured');
  thrWarn = signal('');
  thrCrit = signal('');
  thrBusy = signal(false);
  thrError = signal<string | null>(null);
  // Desired-state sub-tab: the full compiled desired_state document for this host
  // (the GPO-merged result of global/OU/group/host layers), rendered as a
  // gpresult-style collapsible report.
  desiredStateFull = signal<CompiledHostState | null>(null);
  desiredConfig = signal<ConfigDesiredResource[] | null>(null);
  desiredJsonLoading = signal(false);
  desiredJsonError = signal<string | null>(null);
  loadDesiredJson(): void {
    const agent = this.agent();
    if (!agent) return;
    this.desiredJsonLoading.set(true);
    this.desiredJsonError.set(null);
    forkJoin({
      state: this.orchestration.desiredState(agent.id),
      config: this.agentService.configDesired(agent.id),
    }).subscribe({
      next: ({ state, config }) => {
        this.desiredStateFull.set(state);
        this.desiredConfig.set(config.resources);
        this.desiredJsonLoading.set(false);
      },
      error: (e: { error?: { detail?: string } }) => {
        this.desiredJsonError.set(e?.error?.detail ?? 'failed to load desired state');
        this.desiredJsonLoading.set(false);
      },
    });
  }
  loadDesiredMonitoring(): void {
    const agent = this.agent();
    if (!agent) return;
    this.orchestration.desiredState(agent.id).subscribe({
      next: (d) => {
        const t = (d.state.monitoring.thresholds ?? {}) as Record<string, { service_name?: string; warn?: number; crit?: number; comparison?: string; source?: string }>;
        this.thresholds.set(Object.entries(t).map(([metric, v]) => ({ metric, ...v })));
        const explain = (d.explain ?? {}) as { assignments?: { plan: string; source: string; version: number | null }[] };
        const srcByPlan = new Map((explain.assignments ?? []).map((a) => [a.plan, a.source] as const));
        this.appliedPlans.set(d.state.orchestration.plans.map((p) => ({ name: p.name, version: p.version, type: p.type, source: srcByPlan.get(p.name) ?? 'ou' })));
      },
      error: () => { this.thresholds.set([]); this.appliedPlans.set([]); },
    });
  }
  openThr(t: { metric: string; warn?: number | null; crit?: number | null }): void {
    this.thrKey.set(t.metric);
    this.thrWarn.set(t.warn === null || t.warn === undefined ? '' : String(t.warn));
    this.thrCrit.set(t.crit === null || t.crit === undefined ? '' : String(t.crit));
    this.thrMode.set('configured');
    this.thrError.set(null);
  }
  // --- add a NEW threshold -------------------------------------------------
  // The table above lists what the host INHERITS (from the compiled desired
  // state), so a metric that has no rule anywhere never appears and could not be
  // configured. This adds one; the metric list is seeded from the host's own
  // metrics so it stays a choice rather than free-text guessing.
  addThr = signal(false);
  newMetric = signal('');
  newService = signal('');
  newComparison = signal('ge');
  newWarn = signal('');
  newCrit = signal('');
  metricOptions = signal<string[]>([]);
  readonly comparisons = [
    { v: 'ge', label: '≥ (at or above)' }, { v: 'gt', label: '> (above)' },
    { v: 'le', label: '≤ (at or below)' }, { v: 'lt', label: '< (below)' },
    { v: 'eq', label: '= (equals)' }, { v: 'ne', label: '≠ (differs)' },
  ];

  startAddThr(): void {
    this.addThr.set(true);
    this.thrKey.set(null);
    this.thrError.set(null);
    this.newMetric.set(''); this.newService.set(''); this.newWarn.set(''); this.newCrit.set('');
    // The check catalog (name, short_description, summary) — so a picked service
    // can show its real check description (the yaml text), not just a glossary.
    if (!this.thrCatalog().length) {
      this.checkService.listChecks().subscribe({
        next: (r) => this.thrCatalog.set(r.checks || []),
        error: () => this.thrCatalog.set([]),
      });
    }
    const agent = this.agent();
    if (agent && !this.metricOptions().length) {
      // the host's own metric names, minus the ones that already have a threshold
      this.agentService.metricNames(agent.id).subscribe({
        next: (r) => {
          const taken = new Set(this.thresholds().map((t) => t.metric));
          this.metricOptions.set([...new Set(r.metrics ?? [])].filter((m) => !taken.has(m)).sort());
        },
        error: () => this.metricOptions.set([]),
      });
    }
  }

  /** Pre-fill a readable service name from the metric (user can override). */
  onNewMetric(v: string): void {
    this.newMetric.set(v);
    if (!this.newService().trim()) {
      this.newService.set(v.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase()));
    }
    this.thrDesc.set(this.metricGlossary(v) || 'A custom metric threshold. Warn/crit grade the reported value.');
  }

  // ---- Add-threshold Miller: pick a check configured on the host ----------
  thrSearch = signal('');
  thrOther = signal(false);
  thrDesc = signal('');

  /** The checks configured on this host = its monitored services, filtered by
   * the search box. This is the left Miller column of Add threshold. */
  addThrServices = computed<ServiceState[]>(() => {
    const q = this.thrSearch().trim().toLowerCase();
    return this.services()
      .filter((s) => s.metric && s.name !== 'Config drift' ? true : !!s.metric)
      .filter((s) => !q || s.name.toLowerCase().includes(q) || (s.metric || '').toLowerCase().includes(q))
      .slice()
      .sort((a, b) => a.name.localeCompare(b.name));
  });

  /** Pick a host check → prefill the threshold form from it + show its
   * description (self-explaining: what it measures, its live result, and what
   * it is currently graded against). */
  pickThrService(s: ServiceState): void {
    this.thrOther.set(false);
    this.newMetric.set(s.metric);
    this.newService.set(s.name);
    if (s.comparison) this.newComparison.set(s.comparison);
    if (s.warn_threshold !== null && s.warn_threshold !== undefined) this.newWarn.set(String(s.warn_threshold));
    if (s.crit_threshold !== null && s.crit_threshold !== undefined) this.newCrit.set(String(s.crit_threshold));
    // Show the real check description. Live parts first so something is always
    // there; the check's yaml description is fetched + prepended when resolved.
    const live: string[] = [];
    if (s.output) live.push(`Latest result: ${s.output}`);
    const graded = thresholdContext(s);
    if (graded) live.push(`Currently graded: ${graded}.`);
    live.push(`Metric: ${s.metric}.`);
    const compose = (desc: string) => this.thrDesc.set([desc, ...live].filter(Boolean).join('\n\n'));
    compose(this.metricGlossary(s.metric));

    // Resolve the check's real description. Try the best candidate names in turn
    // (catalog match, the raw service name, the metric) — robust even if the
    // catalog hasn't loaded yet, since services are often named after their check.
    const match = this.matchCheckForService(s);
    const candidates = [...new Set([match?.name, s.name, s.metric].filter((x): x is string => !!x))];
    const tryNext = (i: number): void => {
      if (i >= candidates.length) { if (match?.summary) compose(match.summary); return; }
      this.checkService.getCheck(candidates[i]).subscribe({
        next: (r) => {
          const d = (r as { metadata?: { description?: string } })?.metadata?.description || '';
          if (d) compose(d); else tryNext(i + 1);
        },
        error: () => tryNext(i + 1),
      });
    };
    tryNext(0);
  }

  /** Best-effort map from a running service to its library check, so we can show
   * the check's own description. Match on the service-name template (short_desc
   * with %s stripped) exactly or as a prefix, else on the metric/name token. */
  private matchCheckForService(s: ServiceState): CheckCatalogEntry | null {
    const cat = this.thrCatalog();
    if (!cat.length) return null;
    const label = (c: CheckCatalogEntry) => (c.short_description || '').replace(/%s/g, '').replace(/\s+/g, ' ').trim().toLowerCase();
    const sn = (s.name || '').trim().toLowerCase();
    const metric = (s.metric || '').trim().toLowerCase();
    // Exact raw name/metric first (services named after their check, e.g.
    // systemd_units_services_summary); then the service-name template exactly;
    // then as a prefix at a word boundary. No loose substring — "md" must not
    // match "systemd…".
    return cat.find((c) => c.name && (c.name.toLowerCase() === sn || c.name.toLowerCase() === metric))
      || cat.find((c) => label(c) && label(c) === sn)
      || cat.find((c) => label(c) && (sn === label(c) || sn.startsWith(label(c) + ' ')))
      || null;
  }
  pickThrOther(): void {
    this.thrOther.set(true);
    this.newMetric.set(''); this.newService.set('');
    this.thrDesc.set('Set a threshold on any metric this host reports, even one without a service yet. Start typing a metric name.');
  }

  /** One-line "what this measures" for the common builtin metrics, so the
   * threshold editor is self-documenting even for metrics without a library
   * check description. */
  private metricGlossary(metric: string): string {
    const m = (metric || '').toLowerCase();
    const G: [RegExp, string][] = [
      [/cpu_load|load1|load5|load15/, 'System load average — the mean number of processes waiting to run; compare against the core count.'],
      [/cpu.*pct|cpu.*percent|cpu_usage/, 'CPU utilisation in percent across all cores.'],
      [/mem.*used.*pct|mem.*percent|memory.*used/, 'RAM in use as a percent of total physical memory.'],
      [/swap/, 'Swap space in use — sustained swapping indicates memory pressure.'],
      [/disk.*used.*pct|fs.*used|filesystem/, 'Filesystem usage in percent; crit before it fills up.'],
      [/disk.*io|iops|read_bytes|write_bytes/, 'Disk I/O throughput / operations per second.'],
      [/uptime/, 'Time since last boot — a sudden drop means the host rebooted.'],
      [/net.*rx|net.*tx|bandwidth|throughput/, 'Network throughput on the interface.'],
      [/temp|temperature/, 'Hardware temperature sensor reading.'],
      [/process|proc_/, 'Per-process resource usage.'],
      [/config_drift/, 'Number of managed config files drifted from desired (out-of-band changes).'],
    ];
    for (const [re, desc] of G) if (re.test(m)) return desc;
    return '';
  }

  createThr(): void {
    const agent = this.agent();
    const metric = this.newMetric().trim();
    if (!agent || !metric) return;
    this.thrBusy.set(true);
    this.thrError.set(null);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const body: any = {
      service_name: this.newService().trim() || metric,
      metric,
      comparison: this.newComparison(),
      warn_threshold: this.newWarn() === '' ? null : Number(this.newWarn()),
      crit_threshold: this.newCrit() === '' ? null : Number(this.newCrit()),
      ...this.thrScopeFields(agent),
      enabled: true,
    };
    if (body.warn_threshold === null && body.crit_threshold === null) {
      this.thrError.set('set at least a warn or a crit value');
      this.thrBusy.set(false);
      return;
    }
    this.monitoringService.createCheckRule(body).subscribe({
      next: () => { this.thrBusy.set(false); this.addThr.set(false); this.loadDesiredMonitoring(); },
      error: (e: { error?: { detail?: string } }) => {
        this.thrError.set(e?.error?.detail ?? 'failed'); this.thrBusy.set(false);
      },
    });
  }

  /** The CheckRule scope fields for the currently selected apply-scope. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private thrScopeFields(agent: { name: string; ou_id?: string | null }): any {
    const scope = this.applyScope();
    if (scope === 'ou') return { scope_type: 'ou', scope_ou_id: agent.ou_id, scope_value: null };
    if (scope.startsWith('group:')) {
      return { scope_type: 'group', scope_ou_id: null,
               scope_value: this.hostGroups().find((g) => 'group:' + g.id === scope)?.name ?? '' };
    }
    return { scope_type: 'host', scope_value: agent.name, scope_ou_id: null };
  }

  applyThr(): void {
    const agent = this.agent();
    const metric = this.thrKey();
    if (!agent || !metric) return;
    const t = this.thresholds().find((x) => x.metric === metric);
    const scope = this.applyScope();
    const scopeFields = scope === 'ou'
      ? { scope_type: 'ou', scope_ou_id: agent.ou_id, scope_value: null }
      : scope.startsWith('group:')
        ? { scope_type: 'group', scope_value: this.scope.groupName(), scope_ou_id: null }
        : { scope_type: 'host', scope_value: agent.name, scope_ou_id: null };
    this.thrBusy.set(true);
    this.thrError.set(null);
    const done = () => { this.thrBusy.set(false); this.thrKey.set(null); this.loadDesiredMonitoring(); };
    const fail = (e: { error?: { detail?: string } }) => { this.thrError.set(e?.error?.detail ?? 'failed'); this.thrBusy.set(false); };
    this.monitoringService.listCheckRules().subscribe({
      next: (rules) => {
        const existing = rules.find((ru) =>
          ru.metric === metric && ru.scope_type === scopeFields.scope_type &&
          (scopeFields.scope_type === 'ou' ? ru.scope_ou_id === agent.ou_id : ru.scope_value === scopeFields.scope_value));
        if (this.thrMode() === 'notconf') {
          if (!existing) { this.thrError.set('no rule at this scope to remove'); this.thrBusy.set(false); return; }
          this.monitoringService.deleteCheckRule(existing.id).subscribe({ next: done, error: fail });
          return;
        }
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const body: any = {
          service_name: t?.service_name ?? metric, metric, comparison: t?.comparison ?? 'ge',
          warn_threshold: this.thrWarn() === '' ? null : Number(this.thrWarn()),
          crit_threshold: this.thrCrit() === '' ? null : Number(this.thrCrit()),
          ...scopeFields, enabled: true,
        };
        if (existing) this.monitoringService.updateCheckRule(existing.id, body).subscribe({ next: done, error: fail });
        else this.monitoringService.createCheckRule(body).subscribe({ next: done, error: fail });
      },
      error: fail,
    });
  }
  // Block K4: apply scope — 'host', 'ou', or 'group:<id>'. OU/group applies save a config policy and
  // converge every member host ("Host A = Host B").
  //
  // The state itself lives in HostConfigScopeService, provided on THIS component so there is one
  // instance per host page. It is a service and not local state because the Configuration editor is
  // being split into panes that measurably share it (applyScope at four places in the threshold pane
  // and as many in the file/settings/template panes) — every slice would otherwise thread the same
  // three bindings. These two lines keep the ~9 existing template bindings working unchanged.
  private scope = inject(HostConfigScopeService);
  applyScope = this.scope.applyScope;
  hostGroups = this.scope.hostGroups;

  private scopeArg(): { ouId?: string; groupId?: string } | undefined {
    return this.scope.scopeArg(this.agent()?.ou_id);
  }
  sourceFor(path: string): string | null {
    return this.drift().sources?.[path] ?? null;
  }

  isManaged(path: string): boolean {
    return this.drift().managed.includes(path);
  }
  driftFor(path: string): StateResourceChange | null {
    return this.drift().drift.find((c) => c.path === path) ?? null;
  }
  /** Per-key drift rows for a managed file that has drifted. */
  driftRows(path: string): { key: string; desired: string; live: string }[] {
    const changed = this.driftFor(path)?.changed;
    if (!changed) return [];
    // plan diff is observed(before) → desired(after); for drift we show desired
    // vs the live value, i.e. after=desired, before=live.
    return Object.entries(changed).map(([key, [live, desired]]) => ({
      key,
      desired: desired === null || desired === undefined ? '(remove)' : this.scalarStr(desired),
      live: live === null || live === undefined ? '—' : this.scalarStr(live),
    }));
  }

  /** Re-sync the whole host to its recorded desired config (converge drift). */
  reapplyConfig(): void {
    const agent = this.agent();
    if (!agent) return;
    this.driftBusy.set(true);
    this.agentService.reapplyConfig(agent.id).subscribe({
      next: () => {
        this.driftBusy.set(false);
        this.loadObserved();
      },
      error: () => this.driftBusy.set(false),
    });
  }

  /** True for the newest generation — the one currently applied. */
  isCurrentGeneration(n: number): boolean {
    const gens = this.generations();
    return gens.length > 0 && n === Math.max(...gens.map((g) => g.number));
  }

  /** Preview a rollback to generation `n`: a dry-run whose plan IS the
   * observed→target diff. Nothing is written. */
  previewRollback(n: number): void {
    const agent = this.agent();
    if (!agent) return;
    this.rollbackTarget.set(n);
    this.rollbackPlan.set(null);
    this.rollbackError.set(null);
    this.rollbackBusy.set(true);
    this.agentService.stateRollback(agent.id, n, true).subscribe({
      next: (res) => {
        this.rollbackPlan.set(res.plan);
        this.rollbackBusy.set(false);
      },
      error: (e) => {
        this.rollbackError.set(e?.error?.detail ?? 'rollback preview failed');
        this.rollbackBusy.set(false);
      },
    });
  }

  cancelRollback(): void {
    this.rollbackTarget.set(null);
    this.rollbackPlan.set(null);
    this.rollbackError.set(null);
  }

  /** Apply the previewed rollback for real, then reload the tab. */
  applyRollback(): void {
    const agent = this.agent();
    const n = this.rollbackTarget();
    if (!agent || n === null) return;
    this.rollbackBusy.set(true);
    this.rollbackError.set(null);
    this.agentService.stateRollback(agent.id, n, false).subscribe({
      next: () => {
        this.rollbackBusy.set(false);
        this.cancelRollback();
        this.loadObserved();
      },
      error: (e) => {
        this.rollbackError.set(e?.error?.detail ?? 'rollback failed');
        this.rollbackBusy.set(false);
      },
    });
  }

  // --- Block F1b: render stored JSON values in the file's native format, and
  // edit + push keyvalue configs (the "server is a key-value document") ---

  /** The config file's values rendered in its native format (ini/yaml/keyvalue)
   * — the DB/API carry structured JSON, but an admin reads ini/yaml. */
  configText(r: { format: string; separator?: string; values?: Record<string, unknown> }): string {
    const v = r.values;
    if (!v) return '';
    switch (r.format) {
      case 'keyvalue':
        return this.kvText(v, r.separator || ' ');
      case 'ini':
        return this.iniText(v);
      case 'yaml':
      case 'json':
        return this.yamlText(v, 0);
      default:
        return JSON.stringify(v, null, 2);
    }
  }

  private scalarStr(v: unknown): string {
    if (v === null || v === undefined) return '';
    if (typeof v === 'string') return v;
    return JSON.stringify(v);
  }

  private kvText(v: Record<string, unknown>, sep: string): string {
    return Object.entries(v)
      .map(([k, val]) => {
        const s = this.scalarStr(val);
        return s === '' ? k : `${k}${sep}${s}`;
      })
      .join('\n');
  }

  private iniText(v: Record<string, unknown>): string {
    const lines: string[] = [];
    const globals = v[''] as Record<string, unknown> | undefined;
    if (globals) for (const [k, val] of Object.entries(globals)) lines.push(`${k} = ${this.scalarStr(val)}`);
    for (const [sec, kv] of Object.entries(v)) {
      if (sec === '') continue;
      if (lines.length) lines.push('');
      lines.push(`[${sec}]`);
      for (const [k, val] of Object.entries((kv as Record<string, unknown>) || {})) lines.push(`${k} = ${this.scalarStr(val)}`);
    }
    return lines.join('\n');
  }

  private yamlText(v: unknown, indent: number): string {
    const pad = '  '.repeat(indent);
    if (Array.isArray(v)) {
      if (!v.length) return `${pad}[]`;
      return v
        .map((item) =>
          item !== null && typeof item === 'object'
            ? `${pad}-\n${this.yamlText(item, indent + 1)}`
            : `${pad}- ${this.scalarStr(item)}`,
        )
        .join('\n');
    }
    if (v !== null && typeof v === 'object') {
      const entries = Object.entries(v as Record<string, unknown>);
      if (!entries.length) return `${pad}{}`;
      return entries
        .map(([k, val]) =>
          val !== null && typeof val === 'object'
            ? `${pad}${k}:\n${this.yamlText(val, indent + 1)}`
            : `${pad}${k}: ${this.scalarStr(val)}`,
        )
        .join('\n');
    }
    return `${pad}${this.scalarStr(v)}`;
  }

  /** A config is editable when we carried its verbatim text (textual file under
   * the size cap). The edit pushes the whole file back via `copy`, so every
   * format works and comments/order/deletions are preserved. */
  isEditable(r: { raw?: string }): boolean {
    return !!r.raw;
  }

  editingPath = signal<string | null>(null);
  editMode = signal<'kv' | 'raw'>('kv');
  editText = signal(''); // raw fallback tier
  editBusy = signal(false);
  editError = signal<string | null>(null);
  editPreview = signal<string | null>(null); // raw dry-run message

  // K1 value editor (codec'd files): key-value rows + the document-loop plan.
  kvRows = signal<{ key: string; value: string }[]>([]);
  private kvOriginalKeys: string[] = [];
  kvPlan = signal<StateResourceChange | null>(null);

  startEdit(r: { path: string; format: string; separator?: string; raw?: string; values?: Record<string, unknown> }): void {
    this.editingPath.set(r.path);
    this.editError.set(null);
    this.editPreview.set(null);
    this.kvPlan.set(null);
    if (r.values) {
      // Codec'd file → edit VALUES via a key-value table (the document loop).
      this.editMode.set('kv');
      const rows = Object.entries(r.values).map(([key, v]) => ({ key, value: this.scalarStr(v) }));
      this.kvRows.set(rows);
      this.kvOriginalKeys = rows.map((x) => x.key);
    } else {
      // No codec → raw-text fallback tier.
      this.editMode.set('raw');
      this.editText.set(r.raw ?? '');
    }
  }

  cancelEdit(): void {
    this.editingPath.set(null);
    this.editPreview.set(null);
    this.editError.set(null);
    this.kvPlan.set(null);
  }

  setKvKey(i: number, key: string): void {
    this.kvRows.update((rows) => rows.map((r, j) => (j === i ? { ...r, key } : r)));
  }
  setKvValue(i: number, value: string): void {
    this.kvRows.update((rows) => rows.map((r, j) => (j === i ? { ...r, value } : r)));
  }
  removeKvRow(i: number): void {
    this.kvRows.update((rows) => rows.filter((_, j) => j !== i));
  }
  addKvRow(): void {
    this.kvRows.update((rows) => [...rows, { key: '', value: '' }]);
  }

  /** Build the desired values map: every current row (key→value) plus any
   * original key the user removed, set to null (codec-level delete). */
  private kvValues(): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    const present = new Set<string>();
    for (const { key, value } of this.kvRows()) {
      const k = key.trim();
      if (!k) continue;
      out[k] = value;
      present.add(k);
    }
    for (const k of this.kvOriginalKeys) if (!present.has(k)) out[k] = null;
    return out;
  }

  private kvResource(r: { path: string; format: string; separator?: string }): ConfigResource {
    return { type: 'config', path: r.path, format: r.format, separator: r.separator, values: this.kvValues() };
  }

  /** Dry-run the value edit through the document loop → per-key diff. */
  previewKv(r: { path: string; format: string; separator?: string }): void {
    const agent = this.agent();
    if (!agent) return;
    this.editBusy.set(true);
    this.editError.set(null);
    this.agentService.statePlan(agent.id, [this.kvResource(r)]).subscribe({
      next: (res) => {
        this.editBusy.set(false);
        this.kvPlan.set((res.changes || []).find((c) => c.path === r.path) ?? { type: 'config', path: r.path, action: 'noop' });
      },
      error: (e) => {
        this.editError.set(e?.error?.detail ?? 'plan failed');
        this.editBusy.set(false);
      },
    });
  }

  /** Apply the value edit → codec merge-write + a new generation, then reload. */
  applyKv(r: { path: string; format: string; separator?: string }): void {
    const agent = this.agent();
    if (!agent) return;
    this.editBusy.set(true);
    this.editError.set(null);
    this.agentService.stateApply(agent.id, [this.kvResource(r)], false, this.scopeArg()).subscribe({
      next: () => {
        this.editBusy.set(false);
        this.cancelEdit();
        this.loadObserved();
      },
      error: (e) => {
        this.editError.set(e?.error?.detail ?? 'apply failed');
        this.editBusy.set(false);
      },
    });
  }

  // --- Block K2: bind a discovered file to a Class-B template + edit via a
  // schema-driven form (opt-in; the raw codec-less alternative is K1's raw
  // fallback, and codec'd files still have the K1 KV editor) ---

  templates = signal<ConfigTemplate[]>([]);

  /** The template whose name matches a config file's basename (sans a
   * .conf/.cfg extension) — chrony.conf→chrony, rsyslog.conf→rsyslog, hosts. */
  templateFor(path: string): ConfigTemplate | null {
    const base = (path.split('/').pop() || '').replace(/\.(conf|cfg)$/, '');
    return this.templates().find((t) => t.name === base) ?? null;
  }

  tplEditPath = signal<string | null>(null);
  tplName = signal('');
  // The shared ParamForm renders the template's fields (one editor across the
  // app — replaced the bespoke tplFields form). It parses per type + emits the
  // full typed value map via (valuesChange); we just hold that.
  tplSchema = signal<ParamSchema>({});
  tplInitial = signal<Record<string, unknown>>({});
  tplParamValues = signal<Record<string, unknown>>({});
  private tplTemplate = '';
  tplRendered = signal<string | null>(null);
  tplBusy = signal(false);
  tplError = signal<string | null>(null);

  startTemplateEdit(r: { path: string }, tpl: ConfigTemplate): void {
    this.cancelEdit();
    this.tplEditPath.set(r.path);
    this.tplName.set(tpl.name);
    this.tplTemplate = tpl.template;
    this.tplRendered.set(null);
    this.tplError.set(null);
    this.tplSchema.set((tpl.schema || {}) as ParamSchema);
    this.tplInitial.set((tpl.sample || {}) as Record<string, unknown>);
    this.tplParamValues.set({});
  }

  cancelTemplateEdit(): void {
    this.tplEditPath.set(null);
    this.tplRendered.set(null);
    this.tplError.set(null);
  }

  /** ParamForm already parsed each field by its schema type and emitted the full
   * value map — just return it (no manual JSON parsing / no throw). */
  private tplValues(): Record<string, unknown> {
    return this.tplParamValues();
  }

  private tplResource(path: string): ConfigResource {
    return { type: 'template_render', path, template: this.tplTemplate, values: this.tplValues() };
  }

  /** Render the template with the form values (dry-run) → the file that would
   * be written. */
  previewTemplate(r: { path: string }): void {
    const agent = this.agent();
    if (!agent) return;
    let values: Record<string, unknown>;
    try {
      values = this.tplValues();
    } catch (e) {
      this.tplError.set('invalid JSON in a list/object field: ' + (e as Error).message);
      return;
    }
    this.tplBusy.set(true);
    this.tplError.set(null);
    this.agentService.renderTemplate(agent.id, this.tplTemplate, values, r.path).subscribe({
      next: (res) => {
        this.tplBusy.set(false);
        this.tplRendered.set(res.result?.data?.rendered ?? '(empty render)');
      },
      error: (e) => {
        this.tplError.set(e?.error?.detail ?? 'render failed');
        this.tplBusy.set(false);
      },
    });
  }

  /** Apply the template through the document loop → renders + writes the file
   * and records a generation. */
  applyTemplate(r: { path: string }): void {
    const agent = this.agent();
    if (!agent) return;
    let resource: ConfigResource;
    try {
      resource = this.tplResource(r.path);
    } catch (e) {
      this.tplError.set('invalid JSON in a list/object field: ' + (e as Error).message);
      return;
    }
    this.tplBusy.set(true);
    this.tplError.set(null);
    this.agentService.stateApply(agent.id, [resource], false, this.scopeArg()).subscribe({
      next: () => {
        this.tplBusy.set(false);
        this.cancelTemplateEdit();
        this.loadObserved();
      },
      error: (e) => {
        this.tplError.set(e?.error?.detail ?? 'apply failed');
        this.tplBusy.set(false);
      },
    });
  }

  /** Per-key diff rows for the KV preview (key: before → after). */
  kvDiffRows(): { key: string; before: string; after: string }[] {
    const changed = this.kvPlan()?.changed;
    if (!changed) return [];
    return Object.entries(changed).map(([key, [b, a]]) => ({
      key,
      before: b === null || b === undefined ? '—' : this.scalarStr(b),
      after: a === null || a === undefined ? '(removed)' : this.scalarStr(a),
    }));
  }

  private pushConfig(r: { path: string }, dryRun: boolean, onDone: (changed: boolean) => void): void {
    const agent = this.agent();
    if (!agent) return;
    this.editBusy.set(true);
    this.editError.set(null);
    this.agentService.writeFileContent(agent.id, r.path, this.editText(), dryRun).subscribe({
      next: (res) => {
        this.editBusy.set(false);
        onDone(!!res.result?.changed);
      },
      error: (e) => {
        this.editError.set(e?.error?.detail ?? 'config write failed');
        this.editBusy.set(false);
      },
    });
  }

  /** Dry-run the edit: the agent reports whether the file would change, without
   * writing. */
  previewEdit(r: { path: string }): void {
    this.pushConfig(r, true, (changed) =>
      this.editPreview.set(changed ? `preview: ${r.path} would change (nothing written yet)` : 'preview: no changes'),
    );
  }

  /** Apply the edit for real (writes the whole file), then reload the tab. */
  applyEdit(r: { path: string }): void {
    this.pushConfig(r, false, () => {
      this.cancelEdit();
      this.loadObserved();
    });
  }

  /** Flatten a plan's non-noop changes into readable "path: key before→after"
   * rows for the rollback preview. */
  rollbackDiffRows(): { path: string; action: string; detail: string }[] {
    const plan = this.rollbackPlan();
    if (!plan) return [];
    const rows: { path: string; action: string; detail: string }[] = [];
    for (const c of plan.changes) {
      if (c.action === 'noop') continue;
      if (c.changed && Object.keys(c.changed).length) {
        for (const [k, [before, after]] of Object.entries(c.changed)) {
          rows.push({ path: c.path, action: c.action, detail: `${k}: ${JSON.stringify(before)} → ${JSON.stringify(after)}` });
        }
      } else {
        rows.push({ path: c.path, action: c.action, detail: c.error ? `error: ${c.error}` : c.action });
      }
    }
    return rows;
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

  // ── P3b: per-host classification editor (criticality / site / tags) ──
  classBusy = signal(false);
  classMsg = signal('');
  siteDraft = signal<string | null>(null);
  newTagKey = signal('');
  newTagVal = signal('');

  tagEntries(agent: Agent): { key: string; value: string }[] {
    return Object.entries(agent.tags ?? {}).map(([key, value]) => ({ key, value: String(value ?? '') }));
  }

  private applyFacets(agent: Agent, body: Partial<MassAssignFacets>, msg: string): void {
    this.classBusy.set(true);
    this.classMsg.set('');
    this.searchService.bulkAssignFacets({ agent_ids: [agent.id], ...body }).subscribe({
      next: () => {
        this.classBusy.set(false);
        this.classMsg.set(msg);
        this.agentService.get(agent.id).subscribe((a) => this.agent.set(a));
      },
      error: () => {
        this.classBusy.set(false);
        this.classMsg.set('Update failed.');
      },
    });
  }

  setCriticality(agent: Agent, value: string): void {
    this.applyFacets(agent, { criticality: value || '' }, value ? `Criticality set to ${value}.` : 'Criticality cleared.');
  }

  setSite(agent: Agent): void {
    const site = (this.siteDraft() ?? agent.site ?? '').trim();
    this.applyFacets(agent, { site }, site ? `Site set to ${site}.` : 'Site cleared.');
    this.siteDraft.set(null);
  }

  addTag(agent: Agent): void {
    const key = this.newTagKey().trim();
    if (!key) return;
    this.applyFacets(agent, { add_tags: { [key]: this.newTagVal().trim() } }, `Tag ${key} added.`);
    this.newTagKey.set('');
    this.newTagVal.set('');
  }

  removeTag(agent: Agent, key: string): void {
    this.applyFacets(agent, { remove_tags: [key] }, `Tag ${key} removed.`);
  }

  /** L7 exchanges newest-first (the agent returns oldest-last). */
  l7EventsNewestFirst(): EbpfL7Event[] {
    return [...(this.ebpf()?.l7_events ?? [])].reverse();
  }

  /** A failed/error L7 outcome — 4xx/5xx HTTP, SQL failed, or a DNS error. */
  isL7Bad(l: EbpfL7Event): boolean {
    return l.status === '4xx' || l.status === '5xx' || l.status === 'failed'
      || l.status === 'servfail' || l.status === 'nxdomain' || l.status === 'refused';
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
      width: 'min(880px, 94vw)',
      maxWidth: '94vw',
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
    return formatMetricValue(value, metric);
  }
  /** Humane value for a service row (unit-aware from metric + name). */
  svcValue(svc: ServiceState): string {
    return formatMetricValue(svc.value, svc.metric, svc.name);
  }

  /** Elapsed-time label for the "Last check" column (Zabbix's own idiom). */
  timeAgo(iso: string): string {
    const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
    if (s < 60) return `${s}s ago`;
    if (s < 3600) return `${Math.floor(s / 60)}m ago`;
    if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
    return `${Math.floor(s / 86400)}d ago`;
  }

  /** Range the eBPF latency heatmaps load — the picker above them writes it, so both
   * follow one selection instead of each hard-coding its own window. */
  // 6h to match the picker's initial selection — the picker only offers 1h/6h/24h/7d,
  // so the old hard-coded 2h had no corresponding button. Like every other range in
  // this page, the window is fixed at selection time rather than sliding.
  ebpfSince = signal(new Date(Date.now() - 6 * 3600 * 1000).toISOString());

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
  badge(status: string) {
    return runStatusBadge(status);
  }

  hasTags(agent: Agent): boolean {
    return Object.keys(agent.metadata ?? {}).length > 0;
  }

  tagsJson(agent: Agent): string {
    return JSON.stringify(agent.metadata);
  }
}
