import { Component, computed, input } from '@angular/core';
import { NgxEchartsDirective } from 'ngx-echarts';
import type { EChartsCoreOption } from 'echarts/core';
import { MetricPoint } from '../../../core/models/agent.model';
import { BM_GREEN } from '../../bm-colors';

/** A single ngx-echarts wrapper reused everywhere a metric time series is
 * plotted (see docs/plan.md's Bossman plan, section C.3). */
@Component({
  selector: 'app-metric-chart',
  standalone: true,
  imports: [NgxEchartsDirective],
  template: `
    @if (points().length) {
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
  points = input.required<MetricPoint[]>();
  metricName = input<string>('');

  chartOptions = computed<EChartsCoreOption>(() => {
    const pts = this.points();
    // Same green-area line CentralStation's dashboard timeseries widget uses
    // (smooth, symbol-less, translucent fill, muted axis/grid) — reused here
    // so a Bossman chart reads identically, just in the Rastafari green
    // instead of CentralStation's blue.
    const axisText = '#94a3b8';
    const gridLine = 'rgba(148, 163, 184, 0.18)';
    return {
      backgroundColor: 'transparent',
      grid: { left: 52, right: 16, top: 24, bottom: 32 },
      tooltip: { trigger: 'axis' },
      xAxis: {
        type: 'time',
        axisLabel: { color: axisText, fontSize: 11 },
        axisLine: { lineStyle: { color: gridLine } },
      },
      yAxis: {
        type: 'value',
        axisLabel: { color: axisText, fontSize: 11 },
        splitLine: { lineStyle: { color: gridLine } },
      },
      series: [
        {
          name: this.metricName(),
          type: 'line',
          smooth: true,
          showSymbol: false,
          data: pts.map((p) => [p.time, p.value]),
          lineStyle: { width: 2, color: BM_GREEN },
          itemStyle: { color: BM_GREEN },
          areaStyle: { color: BM_GREEN, opacity: 0.15 },
        },
      ],
    };
  });
}
