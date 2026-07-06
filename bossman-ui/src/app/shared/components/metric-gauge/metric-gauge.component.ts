import { Component, computed, input } from '@angular/core';
import { NgxEchartsDirective } from 'ngx-echarts';
import type { EChartsCoreOption } from 'echarts/core';
import { BM_GREEN, BM_GOLD, BM_RED } from '../../bm-colors';

/** A percentage gauge, modeled directly on CentralStation's dashboard
 * `gaugeOptions()` (an ECharts `type: 'gauge'` with warn/crit colour zones
 * on the arc and a big centred value) — reused here for a metric's current
 * %-value in the host-detail Metrics tab's expanded panel, alongside the
 * green-area history chart. Ported to Bossman's Rastafari palette
 * (green/gold/red) instead of CentralStation's blue. */
@Component({
  selector: 'app-metric-gauge',
  standalone: true,
  imports: [NgxEchartsDirective],
  template: `<echarts [options]="options()" class="bm-gauge"></echarts>`,
  styles: [
    `
      .bm-gauge {
        height: 160px;
        width: 100%;
        display: block;
      }
    `,
  ],
})
export class MetricGaugeComponent {
  value = input.required<number>();
  warn = input<number>(80);
  crit = input<number>(90);
  label = input<string>('');

  options = computed<EChartsCoreOption>(() => {
    const pct = this.value();
    const warn = this.warn();
    const crit = this.crit();
    const color = pct >= crit ? BM_RED : pct >= warn ? BM_GOLD : BM_GREEN;
    return {
      backgroundColor: 'transparent',
      series: [
        {
          type: 'gauge',
          startAngle: 210,
          endAngle: -30,
          min: 0,
          max: 100,
          radius: '92%',
          center: ['50%', '58%'],
          splitNumber: 5,
          axisLine: {
            lineStyle: {
              width: 12,
              color: [
                [warn / 100, BM_GREEN],
                [crit / 100, BM_GOLD],
                [1, BM_RED],
              ],
            },
          },
          pointer: { width: 5, length: '62%', itemStyle: { color } },
          axisTick: { show: false },
          splitLine: { show: false },
          axisLabel: { show: false },
          detail: {
            fontSize: 22,
            fontWeight: 700,
            color,
            offsetCenter: [0, '18%'],
            formatter: '{value}%',
          },
          title: { offsetCenter: [0, '46%'], fontSize: 11, color: '#94a3b8' },
          data: [{ value: Math.round(pct * 10) / 10, name: this.label() }],
        },
      ],
    };
  });
}
