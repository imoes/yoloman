import { Component, computed, effect, inject, input, signal } from '@angular/core';
import { NgxEchartsDirective } from 'ngx-echarts';
import { AgentService } from '../../core/services/agent.service';

interface Cell { t: number; le: string; count: number; }

/**
 * A Coroot-style latency heatmap: the agent emits per-interval latency
 * histograms (conn_latency_bucket / disk_io_latency_bucket, one series per `le`
 * bucket); this pivots them into a buckets×time grid where color intensity is
 * the event count in that latency bucket during that interval. Rendered with
 * ECharts' heatmap (the same lib the topology map uses).
 */
@Component({
  selector: 'app-latency-heatmap',
  standalone: true,
  imports: [NgxEchartsDirective],
  template: `
    <div class="bm-hm">
      <div class="bm-hm-title">{{ title() }}</div>
      @if (empty()) {
        <p class="bm-hm-empty">No {{ title().toLowerCase() }} recorded in this window.</p>
      } @else {
        <div echarts [options]="options()" class="bm-hm-chart"></div>
      }
    </div>
  `,
  styles: [`
    .bm-hm { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 10px 12px; }
    .bm-hm-title { font-weight: 600; margin-bottom: 6px; }
    .bm-hm-chart { height: 220px; width: 100%; }
    .bm-hm-empty { opacity: 0.6; font-size: 13px; padding: 24px 0; text-align: center; }
  `],
})
export class LatencyHeatmapComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();
  metric = input.required<string>();
  title = input('Latency');
  /**
   * ISO timestamp to load from — the same shape app-time-range-picker emits, so the
   * heatmap follows the page's range instead of a window of its own. Defaults to two
   * hours, which is what it used to hard-code.
   */
  since = input<string>(new Date(Date.now() - 2 * 3600 * 1000).toISOString());

  private cells = signal<Cell[]>([]);
  // All-zero (or no cells) counts as no data — the ladder is emitted every
  // interval even on an idle host, so length alone isn't enough.
  empty = computed(() => !this.cells().some((c) => c.count > 0));

  constructor() {
    // Reload whenever agent, metric or the selected range changes. This replaces a
    // setInterval(500ms) that polled the inputs for changes: it ran forever, per
    // instance, and was never torn down — an effect tracks the signals directly and
    // dies with the component.
    effect(() => {
      const id = this.agentId();
      const metric = this.metric();
      const since = this.since();
      if (id && metric) this.load(id, metric, since);
    });
  }

  private load(agentId: string, metric: string, since: string): void {
    this.agentService.metricSeries(agentId, metric, since).subscribe({
      next: (r) => {
        // Keep every bucket, including zero-count ones: the agent emits the
        // whole ladder each interval, and we want the full y-axis of buckets
        // visible so a lone active bucket shows WHERE on the ladder it sits
        // (not a context-free solid block). `empty()` still treats an
        // all-zero series as no data.
        const cells: Cell[] = (r.points || [])
          .filter((p) => p.labels && p.labels['le'] != null)
          .map((p) => ({ t: new Date(p.time).getTime(), le: String(p.labels['le']), count: p.value }));
        this.cells.set(cells);
      },
      error: () => this.cells.set([]),
    });
  }

  // Sort le buckets numerically, with "+Inf" last.
  private leOrder = (a: string, b: string) =>
    (a === '+Inf' ? Infinity : parseFloat(a)) - (b === '+Inf' ? Infinity : parseFloat(b));

  options = computed(() => {
    const cells = this.cells();
    const times = [...new Set(cells.map((c) => c.t))].sort((a, b) => a - b);
    const les = [...new Set(cells.map((c) => c.le))].sort(this.leOrder);
    const tIdx = new Map(times.map((t, i) => [t, i]));
    const leIdx = new Map(les.map((l, i) => [l, i]));
    // Color on a log scale so a single dominant bucket (block-I/O piles ~all
    // events into the smallest bucket) doesn't wash every other row to black;
    // the raw count is carried in data[3] for the tooltip.
    const data = cells.map((c) => [tIdx.get(c.t), leIdx.get(c.le), Math.log10(c.count + 1), Math.round(c.count)]);
    const maxCount = Math.max(1, ...cells.map((c) => c.count));
    const maxColor = Math.log10(maxCount + 1);
    const txt = getComputedStyle(document.documentElement).getPropertyValue('--mat-sys-on-surface').trim() || '#888';
    return {
      backgroundColor: 'transparent',
      tooltip: {
        formatter: (p: { data: [number, number, number, number] }) =>
          `≤ ${les[p.data[1]]} ms<br/>${p.data[3]} events`,
      },
      grid: { top: 10, bottom: 40, left: 55, right: 15 },
      xAxis: {
        type: 'category',
        data: times.map((t) => new Date(t).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })),
        axisLabel: { color: txt, fontSize: 10, hideOverlap: true },
        splitArea: { show: false },
      },
      yAxis: {
        type: 'category', name: 'ms', nameTextStyle: { color: txt, fontSize: 10 },
        data: les, axisLabel: { color: txt, fontSize: 10 },
      },
      visualMap: {
        min: 0, max: maxColor, calculable: false, show: false,
        inRange: { color: ['#0b3d2e', '#1e9600', '#ffdd57', '#f44034'] },
      },
      series: [{ type: 'heatmap', data, emphasis: { itemStyle: { borderColor: txt, borderWidth: 1 } } }],
    };
  });
}
