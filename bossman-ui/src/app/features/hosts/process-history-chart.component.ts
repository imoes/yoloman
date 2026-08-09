import { Component, computed, inject, input, signal } from '@angular/core';
import { NgxEchartsDirective } from 'ngx-echarts';
import type { EChartsCoreOption } from 'echarts/core';
import { AgentService } from '../../core/services/agent.service';
import { BM_GREEN, BM_GOLD } from '../../shared/bm-colors';

/**
 * A combined CPU%/RSS history graph for one process, shown when a Processes-tab
 * row is expanded. CPU% and memory live on different scales, so they get their
 * own y-axis (CPU% left, RAM right) on a shared time axis — one glance shows
 * how a process's compute and memory footprint developed over time.
 */
@Component({
  selector: 'app-process-history-chart',
  standalone: true,
  imports: [NgxEchartsDirective],
  template: `
    @if (loading()) {
      <p class="bm-ph-empty">Loading history…</p>
    } @else if (empty()) {
      <p class="bm-ph-empty">No history recorded yet for this process.</p>
    } @else {
      <div echarts [options]="options()" class="bm-ph-chart"></div>
    }
  `,
  styles: [`
    .bm-ph-chart { height: 200px; width: 100%; }
    .bm-ph-empty { opacity: 0.6; font-size: 13px; padding: 16px 0; }
  `],
})
export class ProcessHistoryChartComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();
  comm = input.required<string>();

  private cpu = signal<[number, number][]>([]);
  private rss = signal<[number, number][]>([]);
  loading = signal(true);
  empty = computed(() => this.cpu().length === 0 && this.rss().length === 0);

  constructor() {
    let last = '';
    setInterval(() => {
      const key = this.agentId() + '|' + this.comm();
      if (key !== last && this.agentId() && this.comm()) {
        last = key;
        this.load();
      }
    }, 300);
  }

  private load(): void {
    const since = new Date(Date.now() - 2 * 3600 * 1000).toISOString();
    this.loading.set(true);
    this.agentService.processHistory(this.agentId(), this.comm(), since).subscribe({
      next: (h) => {
        this.cpu.set((h.cpu_percent || []).map((p) => [new Date(p.time).getTime(), p.value]));
        this.rss.set((h.rss_bytes || []).map((p) => [new Date(p.time).getTime(), p.value]));
        this.loading.set(false);
      },
      error: () => {
        this.cpu.set([]);
        this.rss.set([]);
        this.loading.set(false);
      },
    });
  }

  options = computed<EChartsCoreOption>(() => {
    const axisText = '#94a3b8';
    const gridLine = 'rgba(148, 163, 184, 0.18)';
    return {
      backgroundColor: 'transparent',
      grid: { left: 52, right: 56, top: 28, bottom: 28 },
      legend: { top: 0, textStyle: { color: axisText, fontSize: 11 }, itemWidth: 14, itemHeight: 8 },
      tooltip: {
        trigger: 'axis',
        valueFormatter: undefined,
      },
      xAxis: {
        type: 'time',
        axisLabel: { color: axisText, fontSize: 10 },
        axisLine: { lineStyle: { color: gridLine } },
      },
      yAxis: [
        {
          type: 'value',
          name: 'CPU %',
          position: 'left',
          nameTextStyle: { color: BM_GREEN, fontSize: 10 },
          axisLabel: { color: axisText, fontSize: 10 },
          splitLine: { lineStyle: { color: gridLine } },
        },
        {
          type: 'value',
          name: 'RAM',
          position: 'right',
          nameTextStyle: { color: BM_GOLD, fontSize: 10 },
          axisLabel: {
            color: axisText,
            fontSize: 10,
            formatter: (v: number) => this.humanBytes(v),
          },
          splitLine: { show: false },
        },
      ],
      series: [
        {
          name: 'CPU %',
          type: 'line',
          smooth: true,
          showSymbol: false,
          yAxisIndex: 0,
          data: this.cpu(),
          lineStyle: { width: 2, color: BM_GREEN },
          itemStyle: { color: BM_GREEN },
          areaStyle: { color: BM_GREEN, opacity: 0.12 },
        },
        {
          name: 'RAM',
          type: 'line',
          smooth: true,
          showSymbol: false,
          yAxisIndex: 1,
          data: this.rss(),
          lineStyle: { width: 2, color: BM_GOLD },
          itemStyle: { color: BM_GOLD },
          tooltip: { valueFormatter: (v: number) => this.humanBytes(v as number) },
        },
      ],
    };
  });

  private humanBytes(v: number): string {
    if (!v) return '0';
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    let i = 0;
    let n = v;
    while (n >= 1024 && i < units.length - 1) {
      n /= 1024;
      i++;
    }
    return `${n.toFixed(n < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
  }
}
