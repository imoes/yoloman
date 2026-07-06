import { Component, computed, input } from '@angular/core';
import { NgxEchartsDirective } from 'ngx-echarts';
import type { EChartsCoreOption } from 'echarts/core';
import { MetricPoint } from '../../../core/models/agent.model';
import { BM_GREEN, BM_GOLD } from '../../bm-colors';

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
    `,
  ],
})
export class MetricChartComponent {
  points = input<MetricPoint[]>([]);
  metricName = input<string>('');
  /** When non-empty, the chart renders these as overlaid named lines instead
   * of the single `points` series (combined-graph mode). */
  series = input<ChartSeries[]>([]);

  private multi = computed(() => this.series().filter((s) => s.points.length));
  hasData = computed(() => this.multi().length > 0 || this.points().length > 0);

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
