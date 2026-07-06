import { Component, computed, input, output } from '@angular/core';
import { DatePipe } from '@angular/common';
import { RouterLink } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { NgxEchartsDirective } from 'ngx-echarts';
import type { EChartsCoreOption } from 'echarts/core';
import {
  DashboardWidget,
  DonutWidgetData,
  GaugeWidgetData,
  ProblemsWidgetData,
  StatWidgetData,
  TimeseriesWidgetData,
  TopHostsWidgetData,
  WidgetData,
} from '../../../core/models/dashboard.model';
import { HostStatusBadgeComponent } from '../host-status-badge/host-status-badge.component';
import { PerfOMeterComponent } from '../perf-o-meter/perf-o-meter.component';
import { serviceStateBadge } from '../../status.util';
import { BM_GOLD, BM_GREEN, BM_RED, BM_UNKNOWN } from '../../bm-colors';

/** The polymorphic per-widget renderer for the GridStack dashboard (see
 * docs/plan.md's monitoring-cockpit ergänzung Block F5) — one component,
 * `@switch`-dispatched on widget_type, modeled directly on CentralStation's
 * own dashboard-widget.component.ts rather than a component-per-type
 * registry. Only the six types Bossman's backend actually produces data
 * for exist here (see dashboard.model.ts's WIDGET_CATALOG). */
@Component({
  selector: 'app-dashboard-widget',
  standalone: true,
  imports: [DatePipe, RouterLink, MatButtonModule, MatIconModule, NgxEchartsDirective, HostStatusBadgeComponent, PerfOMeterComponent],
  template: `
    <div class="bm-widget">
      <div class="bm-widget-header">
        <span class="bm-widget-title">{{ widget().title }}</span>
        @if (editMode()) {
          <div class="bm-widget-actions">
            <button mat-icon-button (click)="remove.emit()" aria-label="Remove widget">
              <mat-icon>close</mat-icon>
            </button>
          </div>
        }
      </div>
      <div class="bm-widget-body">
        @switch (widget().widget_type) {
          @case ('top_hosts') {
            @if (topHosts().length) {
              <table class="bm-widget-table">
                <thead>
                  <tr>
                    <th>Host</th>
                    <th>CPU</th>
                    <th>Mem</th>
                    <th>Disk</th>
                  </tr>
                </thead>
                <tbody>
                  @for (h of topHosts(); track h.id) {
                    <tr [routerLink]="['/hosts', h.id]" class="bm-row-link">
                      <td>
                        <app-status-badge [status]="badgeOf(h.state_rollup)" [label]="h.name" />
                      </td>
                      <td><app-perf-o-meter [value]="h.cpu_load" [max]="100" [warn]="70" [crit]="90" unit="" /></td>
                      <td><app-perf-o-meter [value]="h.mem_used_pct" [warn]="80" [crit]="95" /></td>
                      <td><app-perf-o-meter [value]="h.disk_used_pct_max" [warn]="80" [crit]="95" /></td>
                    </tr>
                  }
                </tbody>
              </table>
            } @else {
              <p class="bm-widget-empty">No hosts yet.</p>
            }
          }
          @case ('problems') {
            @if (problems().length) {
              <table class="bm-widget-table">
                <thead>
                  <tr>
                    <th>Host</th>
                    <th>Service</th>
                    <th>State</th>
                    <th>Since</th>
                  </tr>
                </thead>
                <tbody>
                  @for (p of problems(); track p.id) {
                    <tr>
                      <td>{{ p.host }}</td>
                      <td>{{ p.name }}</td>
                      <td><app-status-badge [status]="badgeOf(p.state)" [label]="p.state" /></td>
                      <td>{{ p.last_state_change | date: 'short' }}</td>
                    </tr>
                  }
                </tbody>
              </table>
            } @else {
              <p class="bm-widget-empty">No open problems.</p>
            }
          }
          @case ('donut') {
            @if (donutBuckets().length) {
              <div echarts [options]="donutOptions()" class="bm-widget-chart"></div>
            } @else {
              <p class="bm-widget-empty">No service data yet.</p>
            }
          }
          @case ('stat') {
            <div class="bm-widget-stat">{{ statValue() ?? '—' }}</div>
            <div class="bm-widget-stat-label">{{ statLabel() }}</div>
          }
          @case ('gauge') {
            @if (gaugeError()) {
              <p class="bm-widget-empty">{{ gaugeError() }}</p>
            } @else {
              <div echarts [options]="gaugeOptions()" class="bm-widget-chart"></div>
            }
          }
          @case ('timeseries') {
            @if (timeseriesError()) {
              <p class="bm-widget-empty">{{ timeseriesError() }}</p>
            } @else if (timeseriesPoints().length) {
              <div echarts [options]="timeseriesOptions()" class="bm-widget-chart"></div>
            } @else {
              <p class="bm-widget-empty">No data for this metric yet.</p>
            }
          }
        }
      </div>
    </div>
  `,
  styles: [
    `
      .bm-widget {
        display: flex;
        flex-direction: column;
        height: 100%;
        background: var(--mat-sys-surface-container);
        border-radius: 8px;
        overflow: hidden;
      }
      .bm-widget-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding: 6px 10px;
        font-size: 13px;
        font-weight: 600;
        border-bottom: 1px solid var(--mat-sys-outline-variant);
        flex: none;
        cursor: move;
      }
      .bm-widget-actions button {
        width: 28px;
        height: 28px;
        line-height: 28px;
      }
      .bm-widget-body {
        flex: 1;
        min-height: 0;
        padding: 8px 10px;
        overflow: auto;
      }
      .bm-widget-table {
        width: 100%;
        border-collapse: collapse;
        font-size: 12px;
      }
      .bm-widget-table th {
        text-align: left;
        opacity: 0.7;
        font-weight: 500;
        padding: 4px 6px;
      }
      .bm-widget-table td {
        padding: 4px 6px;
        border-top: 1px solid var(--mat-sys-outline-variant);
      }
      .bm-row-link {
        cursor: pointer;
      }
      .bm-row-link:hover {
        background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent);
      }
      .bm-widget-empty {
        opacity: 0.6;
        font-size: 12px;
        margin: 0;
      }
      .bm-widget-chart {
        height: 100%;
        width: 100%;
        min-height: 100px;
        display: block;
      }
      .bm-widget-stat {
        font-size: 36px;
        font-weight: 700;
        line-height: 1.1;
      }
      .bm-widget-stat-label {
        font-size: 12px;
        opacity: 0.7;
        text-transform: uppercase;
        letter-spacing: 0.04em;
      }
    `,
  ],
})
export class DashboardWidgetComponent {
  widget = input.required<DashboardWidget>();
  data = input<WidgetData | null>(null);
  editMode = input<boolean>(false);
  remove = output<void>();

  badgeOf(state: string) {
    return serviceStateBadge(state);
  }

  topHosts = computed(() => (this.data() as TopHostsWidgetData | null)?.hosts ?? []);
  problems = computed(() => (this.data() as ProblemsWidgetData | null)?.problems ?? []);
  donutBuckets = computed(() => (this.data() as DonutWidgetData | null)?.buckets ?? []);
  statValue = computed(() => (this.data() as StatWidgetData | null)?.value ?? null);
  statLabel = computed(() => (this.data() as StatWidgetData | null)?.label ?? '');
  gaugeError = computed(() => (this.data() as GaugeWidgetData | null)?.error ?? '');
  timeseriesError = computed(() => (this.data() as TimeseriesWidgetData | null)?.error ?? '');
  timeseriesPoints = computed(() => (this.data() as TimeseriesWidgetData | null)?.points ?? []);

  private readonly stateColors: Record<string, string> = { OK: BM_GREEN, WARN: BM_GOLD, CRIT: BM_RED, UNKNOWN: BM_UNKNOWN };

  donutOptions = computed<EChartsCoreOption>(() => {
    const buckets = this.donutBuckets();
    return {
      backgroundColor: 'transparent',
      tooltip: { trigger: 'item', formatter: '{b}: {c} ({d}%)' },
      legend: { bottom: 0, textStyle: { fontSize: 11 } },
      series: [
        {
          type: 'pie',
          radius: ['42%', '68%'],
          center: ['50%', '44%'],
          label: { show: false },
          data: buckets.map((b) => ({ name: b.key, value: b.count, itemStyle: { color: this.stateColors[b.key] ?? BM_UNKNOWN } })),
        },
      ],
    };
  });

  gaugeOptions = computed<EChartsCoreOption>(() => {
    const d = this.data() as GaugeWidgetData | null;
    const value = d?.value ?? 0;
    const warn = d?.warn ?? 70;
    const crit = d?.crit ?? 90;
    const color = value >= crit ? BM_RED : value >= warn ? BM_GOLD : BM_GREEN;
    return {
      backgroundColor: 'transparent',
      series: [
        {
          type: 'gauge',
          startAngle: 210,
          endAngle: -30,
          min: 0,
          max: 100,
          radius: '90%',
          center: ['50%', '58%'],
          axisLine: { lineStyle: { width: 12, color: [[warn / 100, BM_GREEN], [crit / 100, BM_GOLD], [1, BM_RED]] } },
          pointer: { width: 4, length: '65%', itemStyle: { color } },
          axisTick: { show: false },
          splitLine: { show: false },
          axisLabel: { show: false },
          detail: { fontSize: 18, fontWeight: 700, color, offsetCenter: [0, '30%'], formatter: '{value}' },
          data: [{ value }],
        },
      ],
    };
  });

  timeseriesOptions = computed<EChartsCoreOption>(() => {
    const points = this.timeseriesPoints();
    return {
      backgroundColor: 'transparent',
      grid: { left: 44, right: 12, top: 12, bottom: 28 },
      tooltip: { trigger: 'axis' },
      xAxis: { type: 'time' },
      yAxis: { type: 'value' },
      series: [
        {
          type: 'line',
          showSymbol: false,
          smooth: true,
          data: points.map((p) => [p.time, p.value]),
          color: BM_GREEN,
          areaStyle: { opacity: 0.1 },
        },
      ],
    };
  });
}
