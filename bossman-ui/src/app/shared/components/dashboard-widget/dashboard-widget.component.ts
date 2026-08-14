import { Component, computed, input, output } from '@angular/core';
import { DatePipe } from '@angular/common';
import { RouterLink } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { NgxEchartsDirective } from 'ngx-echarts';
import type { EChartsCoreOption } from 'echarts/core';
import {
  AiSummaryWidgetData,
  BarWidgetData,
  CalloutWidgetData,
  DashboardWidget,
  DonutWidgetData,
  GaugeWidgetData,
  LogWidgetData,
  ProblemsWidgetData,
  ProgressWidgetData,
  StatWidgetData,
  StatusTilesWidgetData,
  TableWidgetData,
  TimeseriesSeries,
  TimeseriesWidgetData,
  TopHostsWidgetData,
  WarRoomWidgetData,
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
            } @else if (timeseriesHasData()) {
              <div echarts [options]="timeseriesOptions()" class="bm-widget-chart"></div>
            } @else {
              <p class="bm-widget-empty">No data for this metric yet.</p>
            }
          }
          @case ('bar') {
            @if (barBuckets().length) {
              <div echarts [options]="barOptions()" class="bm-widget-chart"></div>
            } @else {
              <p class="bm-widget-empty">No data.</p>
            }
          }
          @case ('table') {
            <table class="bm-widget-table">
              <thead><tr>@for (c of tableColumns(); track $index) { <th>{{ c }}</th> }</tr></thead>
              <tbody>
                @for (row of tableRows(); track $index) {
                  <tr>@for (cell of row; track $index) { <td>{{ cell }}</td> }</tr>
                }
              </tbody>
            </table>
          }
          @case ('status_tiles') {
            <div class="bm-tiles">
              @for (t of tiles(); track $index) {
                <div class="bm-tile" [style.border-left-color]="tileColor(t.state)">
                  <span class="bm-tile-label">{{ t.label }}</span>
                  @if (t.sub) { <span class="bm-tile-sub">{{ t.sub }}</span> }
                </div>
              }
            </div>
          }
          @case ('progress') {
            <div class="bm-progress-list">
              @for (p of progressItems(); track $index) {
                <div class="bm-progress-row">
                  <span class="bm-progress-label">{{ p.label }}</span>
                  <div class="bm-progress-track"><div class="bm-progress-fill" [style.width.%]="pct(p)" [style.background]="tileColor(p.state ?? 'OK')"></div></div>
                  <span class="bm-progress-val">{{ p.value }}{{ p.max ? '/' + p.max : '' }}</span>
                </div>
              }
            </div>
          }
          @case ('ai_summary') {
            <div class="bm-summary">
              <p>{{ aiSummary().summary }}</p>
              @if (aiSummary().findings?.length) {
                <h5>Findings</h5><ul>@for (f of aiSummary().findings!; track $index) { <li>{{ f }}</li> }</ul>
              }
              @if (aiSummary().recommendations?.length) {
                <h5>Recommendations</h5><ul>@for (r of aiSummary().recommendations!; track $index) { <li>{{ r }}</li> }</ul>
              }
            </div>
          }
          @case ('war_room') {
            <div class="bm-warroom" [style.border-left-color]="tileColor(warRoom().severity)">
              <div class="bm-warroom-head" [style.color]="tileColor(warRoom().severity)">
                {{ warRoom().active ? 'ACTIVE INCIDENT' : 'Situation' }} — {{ warRoom().severity ?? '—' }}
              </div>
              @if (warRoom().findings?.length) {
                <h5>Findings</h5><ul>@for (f of warRoom().findings!; track $index) { <li>{{ f }}</li> }</ul>
              }
              @if (warRoom().blast_radius?.length) {
                <h5>Blast radius</h5><ul>@for (b of warRoom().blast_radius!; track $index) { <li>{{ b }}</li> }</ul>
              }
              @if (warRoom().recommendations?.length) {
                <h5>Recommendations</h5><ul>@for (r of warRoom().recommendations!; track $index) { <li>{{ r }}</li> }</ul>
              }
            </div>
          }
          @case ('log') {
            <pre class="bm-widget-log">@for (l of logLines(); track $index) {<span>{{ l }}
</span>}</pre>
          }
          @case ('callout') {
            <div class="bm-callout bm-callout-{{ callout().level ?? 'info' }}">{{ callout().text }}</div>
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
      /* Block W1 additions */
      .bm-tiles { display: flex; flex-wrap: wrap; gap: 6px; }
      .bm-tile { display: flex; flex-direction: column; padding: 4px 8px; border-left: 3px solid var(--bm-unknown); background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); border-radius: 4px; min-width: 70px; }
      .bm-tile-label { font-size: 12px; }
      .bm-tile-sub { font-size: 10px; opacity: 0.7; }
      .bm-progress-list { display: flex; flex-direction: column; gap: 6px; }
      .bm-progress-row { display: flex; align-items: center; gap: 8px; font-size: 12px; }
      .bm-progress-label { flex: 0 0 30%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .bm-progress-track { flex: 1; height: 10px; background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); border-radius: 5px; overflow: hidden; }
      .bm-progress-fill { height: 100%; }
      .bm-progress-val { flex: none; font-variant-numeric: tabular-nums; opacity: 0.8; }
      .bm-summary, .bm-warroom { font-size: 13px; overflow: auto; }
      .bm-summary h5, .bm-warroom h5 { margin: 8px 0 2px; font-size: 11px; text-transform: uppercase; opacity: 0.6; }
      .bm-summary ul, .bm-warroom ul { margin: 0; padding-left: 18px; }
      .bm-warroom { border-left: 4px solid var(--bm-unknown); padding-left: 8px; }
      .bm-warroom-head { font-weight: 700; font-size: 12px; margin-bottom: 4px; }
      .bm-widget-log { margin: 0; max-height: 100%; overflow: auto; background: #1e1e1e; color: #d4d4d4; padding: 8px; border-radius: 6px; font-size: 11px; white-space: pre-wrap; word-break: break-word; }
      .bm-callout { padding: 8px 12px; border-radius: 6px; font-size: 13px; border-left: 4px solid; }
      .bm-callout-info { border-left-color: #569cd6; background: color-mix(in srgb, #569cd6 12%, transparent); }
      .bm-callout-success { border-left-color: var(--bm-green); background: color-mix(in srgb, var(--bm-green) 12%, transparent); }
      .bm-callout-warn { border-left-color: var(--bm-gold); background: color-mix(in srgb, var(--bm-gold) 14%, transparent); }
      .bm-callout-error { border-left-color: var(--bm-red); background: color-mix(in srgb, var(--bm-red) 12%, transparent); }
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
  /** Every line to draw. A widget that references a saved graph delivers N of them (across
   * hosts, with their own colour and axis); the inline agent+metric case delivers one. The
   * fallback keeps widgets stored before `series` existed rendering unchanged. */
  timeseriesSeries = computed<TimeseriesSeries[]>(() => {
    const d = this.data() as TimeseriesWidgetData | null;
    if (d?.series?.length) return d.series;
    if (d?.points?.length) {
      return [{ item_id: null, agent_id: '', metric: '', label: null, color: BM_GREEN,
                draw_style: 'line', axis_side: 'left', resolution: d.resolution ?? 'raw',
                points: d.points }];
    }
    return [];
  });
  /** True once anything is plottable — the template used to test `points` only, which left a
   * graph-backed widget claiming "No data" while it had series. */
  timeseriesHasData = computed(() => this.timeseriesSeries().some((s) => s.points.length > 0));
  /** The resolutions actually served, so mixed tiers are visible rather than implied. */
  timeseriesResolution = computed(() => {
    const tiers = [...new Set(this.timeseriesSeries().map((s) => s.resolution).filter(Boolean))];
    return tiers.length === 1 ? tiers[0] : tiers.join(' + ');
  });

  private readonly stateColors: Record<string, string> = { OK: BM_GREEN, WARN: BM_GOLD, CRIT: BM_RED, UNKNOWN: BM_UNKNOWN };

  // ---- Block W1: additional widget accessors ----
  barBuckets = computed(() => (this.data() as BarWidgetData | null)?.buckets ?? []);
  tableColumns = computed(() => (this.data() as TableWidgetData | null)?.columns ?? []);
  tableRows = computed(() => (this.data() as TableWidgetData | null)?.rows ?? []);
  tiles = computed(() => (this.data() as StatusTilesWidgetData | null)?.tiles ?? []);
  progressItems = computed(() => (this.data() as ProgressWidgetData | null)?.items ?? []);
  aiSummary = computed(() => (this.data() as AiSummaryWidgetData | null) ?? { summary: '' });
  warRoom = computed(() => (this.data() as WarRoomWidgetData | null) ?? {});
  callout = computed(() => (this.data() as CalloutWidgetData | null) ?? { text: '' });
  logLines = computed<string[]>(() => {
    const d = this.data() as LogWidgetData | null;
    if (!d) return [];
    if (d.lines?.length) return d.lines;
    return (d.entries ?? []).map((e) => `${e.timestamp ?? ''} ${e.unit ?? ''} ${e.message}`.trim());
  });

  tileColor(state?: string): string {
    return this.stateColors[state ?? 'UNKNOWN'] ?? BM_UNKNOWN;
  }
  pct(item: { value: number; max?: number }): number {
    const max = item.max ?? 100;
    return max > 0 ? Math.min(100, Math.max(0, (item.value / max) * 100)) : 0;
  }

  barOptions = computed<EChartsCoreOption>(() => {
    const buckets = this.barBuckets();
    return {
      backgroundColor: 'transparent',
      tooltip: { trigger: 'axis' },
      grid: { left: 8, right: 12, top: 12, bottom: 8, containLabel: true },
      xAxis: { type: 'category', data: buckets.map((b) => b.key), axisLabel: { fontSize: 10 } },
      yAxis: { type: 'value', axisLabel: { fontSize: 10 } },
      series: [
        {
          type: 'bar',
          data: buckets.map((b) => ({ value: b.count, itemStyle: { color: this.stateColors[b.key] ?? BM_GREEN } })),
        },
      ],
    };
  });

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

  /** One builder for both shapes. A saved graph's per-series draw style and axis side are
   * honoured here, because they are the reason a graph is not just "a timeseries widget with
   * more lines": a metric in percent and one in bytes need separate axes to be readable. */
  timeseriesOptions = computed<EChartsCoreOption>(() => {
    const series = this.timeseriesSeries();
    const usesRight = series.some((s) => s.axis_side === 'right');
    const legend = series.length > 1 && (this.data() as TimeseriesWidgetData | null)?.graph?.show_legend !== false;
    return {
      backgroundColor: 'transparent',
      grid: { left: 44, right: usesRight ? 44 : 12, top: legend ? 28 : 12, bottom: 28 },
      tooltip: { trigger: 'axis' },
      legend: legend ? { top: 0, textStyle: { fontSize: 10 } } : undefined,
      xAxis: { type: 'time' },
      yAxis: usesRight
        ? [{ type: 'value' }, { type: 'value' }]
        : { type: 'value' },
      series: series.map((s) => ({
        type: 'line',
        name: s.label || s.metric || 'value',
        showSymbol: s.draw_style === 'dot',
        smooth: s.draw_style !== 'dot',
        lineStyle: {
          width: s.draw_style === 'bold_line' ? 3 : 2,
          type: s.draw_style === 'dashed' ? 'dashed' : 'solid',
        },
        yAxisIndex: usesRight && s.axis_side === 'right' ? 1 : 0,
        data: s.points.map((p) => [p.time, p.value]),
        color: s.color || BM_GREEN,
        // Filling several overlapping lines makes them unreadable, so the area is kept for
        // the single-line case (and for an explicitly filled/gradient item).
        areaStyle:
          s.draw_style === 'filled' || s.draw_style === 'gradient' || series.length === 1
            ? { opacity: 0.1 }
            : undefined,
      })),
    };
  });
}
