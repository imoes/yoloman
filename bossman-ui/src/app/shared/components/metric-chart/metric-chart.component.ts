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
    return {
      backgroundColor: 'transparent',
      grid: { left: 48, right: 16, top: 24, bottom: 32 },
      tooltip: { trigger: 'axis' },
      xAxis: { type: 'time' },
      yAxis: { type: 'value' },
      series: [
        {
          name: this.metricName(),
          type: 'line',
          showSymbol: false,
          data: pts.map((p) => [p.time, p.value]),
          color: BM_GREEN,
          areaStyle: { opacity: 0.08 },
        },
      ],
    };
  });
}
