import { Component, computed, input } from '@angular/core';
import { NgxEchartsDirective } from 'ngx-echarts';
import type { EChartsCoreOption } from 'echarts/core';
import { MetricPoint } from '../../../core/models/agent.model';
import { BM_GREEN, BM_GOLD } from '../../bm-colors';
import { formatMetricValue } from '../../format.util';

/** min/max/avg of one line over the displayed window — Checkmk shows these under every metric. */
interface SeriesStats {
  name: string;
  min: number;
  max: number;
  avg: number;
}

/** One named line for the overlay/combined-graph mode. */
export interface ChartSeries {
  name: string;
  points: MetricPoint[];
}

/** Palette for combined graphs — Bossman green/gold first, then a spread of
 * distinct hues, mirroring CentralStation's own multi-series line palette so
 * an overlaid Bossman chart reads the same way. */
const SERIES_PALETTE = [BM_GREEN, BM_GOLD, '#4fd6ff', '#a78bfa', '#fb7185', '#f97316'];

/** A single ngx-echarts wrapper reused everywhere a metric time series is
 * plotted (see docs/plan.md's Bossman plan, section C.3). Two modes: a single
 * green-area line (`points`) or a CheckMK-style combined graph overlaying
 * several named lines (`series`) — e.g. cpu_load1/5/15 in one chart. */
@Component({
  selector: 'app-metric-chart',
  standalone: true,
  imports: [NgxEchartsDirective],
  template: `
    @if (hasData()) {
      <echarts [options]="chartOptions()" class="bm-chart"></echarts>
      <!-- min/max/avg over the shown range, Checkmk-style. One row per line in a combined graph. -->
      @for (st of stats(); track st.name) {
        <div class="bm-chart-stats">
          @if (st.name) { <span class="bm-chart-stats__name">{{ st.name }}</span> }
          <span><b>min</b> {{ fmt(st.min) }}</span>
          <span><b>max</b> {{ fmt(st.max) }}</span>
          <span><b>avg</b> {{ fmt(st.avg) }}</span>
        </div>
      }
    } @else {
      <div class="bm-chart-empty">No data for {{ metricName() }}</div>
    }
  `,
  styles: [
    `
      .bm-chart {
        height: 240px;
        width: 100%;
        display: block;
      }
      .bm-chart-empty {
        display: flex;
        align-items: center;
        justify-content: center;
        height: 240px;
        color: var(--mat-sys-outline);
        font-size: 13px;
      }
      .bm-chart-stats {
        display: flex;
        flex-wrap: wrap;
        gap: 4px 16px;
        font-size: 12px;
        color: var(--mat-sys-outline);
        padding: 4px 8px 0;
      }
      .bm-chart-stats__name {
        font-weight: 600;
        color: var(--mat-sys-on-surface);
        min-width: 6em;
      }
      .bm-chart-stats b {
        font-weight: 600;
        color: var(--mat-sys-on-surface);
      }
    `,
  ],
})
export class MetricChartComponent {
  points = input<MetricPoint[]>([]);
  metricName = input<string>('');
  /** When non-empty, the chart renders these as overlaid named lines instead
   * of the single `points` series (combined-graph mode). */
  series = input<ChartSeries[]>([]);
  /** Optional explicit x-axis window (epoch ms). When set, the time axis
   * spans exactly this range instead of auto-fitting to the data extent — so
   * a "365d" selection reads as a year even when only a few days of data
   * exist (data then sits at the right edge, à la Grafana/CheckMK). */
  windowStartMs = input<number | null>(null);
  windowEndMs = input<number | null>(null);

  private multi = computed(() => this.series().filter((s) => s.points.length));
  hasData = computed(() => this.multi().length > 0 || this.points().length > 0);

  /** min/max/avg over the currently displayed points — recomputed when the range (and thus the
   *  loaded points) changes, so it always reflects exactly what the chart shows. One entry per line
   *  in combined-graph mode, a single unnamed entry otherwise. */
  stats = computed<SeriesStats[]>(() => {
    const multi = this.multi();
    if (multi.length) {
      return multi.map((s) => this.statsOf(s.name, s.points)).filter((x): x is SeriesStats => x !== null);
    }
    const s = this.statsOf('', this.points());
    return s ? [s] : [];
  });

  private statsOf(name: string, pts: MetricPoint[]): SeriesStats | null {
    const vals = pts.map((p) => p.value).filter((v) => v !== null && v !== undefined && isFinite(v));
    if (!vals.length) return null;
    let min = vals[0];
    let max = vals[0];
    let sum = 0;
    for (const v of vals) {
      if (v < min) min = v;
      if (v > max) max = v;
      sum += v;
    }
    return { name, min, max, avg: sum / vals.length };
  }

  /** Unit-aware, 2-decimal formatting — the same formatter the value columns use, so the summary and
   *  the live value read identically. */
  fmt(v: number): string {
    return formatMetricValue(v, this.metricName());
  }

  chartOptions = computed<EChartsCoreOption>(() => {
    // Same green-area / multi-line styling CentralStation's dashboard timeseries
    // widget uses (smooth, symbol-less, translucent fill, muted axis/grid) —
    // reused here so a Bossman chart reads identically, in Rastafari green.
    const axisText = '#94a3b8';
    const gridLine = 'rgba(148, 163, 184, 0.18)';
    const multi = this.multi();

    const base = {
      backgroundColor: 'transparent',
      grid: { left: 52, right: 16, top: multi.length ? 36 : 24, bottom: 32 },
      tooltip: { trigger: 'axis' as const },
      xAxis: {
        type: 'time' as const,
        // Pin the axis to the selected window when given, so the picked range
        // is always reflected (365d looks like a year, not the data extent).
        ...(this.windowStartMs() != null ? { min: this.windowStartMs() } : {}),
        ...(this.windowEndMs() != null ? { max: this.windowEndMs() } : {}),
        axisLabel: { color: axisText, fontSize: 11 },
        axisLine: { lineStyle: { color: gridLine } },
      },
      yAxis: {
        type: 'value' as const,
        axisLabel: { color: axisText, fontSize: 11 },
        splitLine: { lineStyle: { color: gridLine } },
      },
    };

    if (multi.length) {
      return {
        ...base,
        legend: {
          top: 4,
          textStyle: { color: axisText, fontSize: 11 },
          itemWidth: 14,
          itemHeight: 8,
        },
        series: multi.map((s, i) => {
          const color = SERIES_PALETTE[i % SERIES_PALETTE.length];
          return {
            name: s.name,
            type: 'line',
            smooth: true,
            showSymbol: false,
            data: s.points.map((p) => [p.time, p.value]),
            lineStyle: { width: 2, color },
            itemStyle: { color },
            // Area fill only when a single line is overlaid; overlapping fills
            // muddy a multi-line combined graph (CentralStation drops it too).
            ...(multi.length === 1 ? { areaStyle: { color, opacity: 0.15 } } : {}),
          };
        }),
      };
    }

    return {
      ...base,
      series: [
        {
          name: this.metricName(),
          type: 'line',
          smooth: true,
          showSymbol: false,
          data: this.points().map((p) => [p.time, p.value]),
          lineStyle: { width: 2, color: BM_GREEN },
          itemStyle: { color: BM_GREEN },
          areaStyle: { color: BM_GREEN, opacity: 0.15 },
        },
      ],
    };
  });
}
