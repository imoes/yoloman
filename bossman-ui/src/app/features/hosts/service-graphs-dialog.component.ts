import { Component, Inject, inject, signal } from '@angular/core';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { forkJoin } from 'rxjs';
import { LatestMetric, MetricPoint } from '../../core/models/agent.model';
import { AgentService } from '../../core/services/agent.service';
import { ChartSeries, MetricChartComponent } from '../../shared/components/metric-chart/metric-chart.component';

export interface ServiceGraphsDialogData {
  agentId: string;
  hostName: string;
  serviceName: string;
  serviceMetric: string;
  /** The host's per-series snapshot — the authority on what it actually reports. */
  available: LatestMetric[];
  hours: number;
}

/** One chart in the dialog. `metrics` are drawn overlaid (same unit); `splitBy`
 * fans one metric out into a line per label value; `filter` pins a single label
 * so a mount's chart shows only its own filesystem. */
interface GraphSpec {
  title: string;
  metrics: string[];
  splitBy?: string;
  filter?: { key: string; value: string };
}

const RANGES = [
  { label: '1h', hours: 1 },
  { label: '6h', hours: 6 },
  { label: '24h', hours: 24 },
  { label: '7d', hours: 168 },
  { label: '30d', hours: 720 },
];

/**
 * Every graph behind one service check, in a popup.
 *
 * The inline expansion under a service row plots the ONE metric the check
 * grades, which is the right default and too little when you are actually
 * investigating: "Memory 60.9%" has six underlying series, and a disk has three.
 * This shows all of them.
 *
 * The set is derived from the host's own snapshot rather than a hardcoded table,
 * so a host that reports no swap gets no empty swap panel, and a metric added to
 * the agent later shows up here without a UI change.
 */
@Component({
  selector: 'app-service-graphs-dialog',
  standalone: true,
  imports: [MatDialogModule, MatButtonModule, MetricChartComponent],
  template: `
    <h2 mat-dialog-title>{{ data.serviceName }} · {{ data.hostName }}</h2>
    <mat-dialog-content>
      <div class="bm-sg-ranges">
        @for (r of ranges; track r.hours) {
          <button mat-button class="bm-sg-range" [class.bm-sg-range--on]="hours() === r.hours" (click)="setRange(r.hours)">
            {{ r.label }}
          </button>
        }
        <span class="bm-sg-count">{{ charts().length }} graphs</span>
      </div>

      @if (loading()) {
        <p class="bm-sg-empty">Loading…</p>
      } @else if (!charts().length) {
        <p class="bm-sg-empty">This service reports no metrics this host has recorded.</p>
      } @else {
        @for (c of charts(); track c.title) {
          <section class="bm-sg-chart">
            <h3>{{ c.title }}</h3>
            <app-metric-chart
              [series]="c.series"
              [metricName]="c.title"
              [windowStartMs]="window().start"
              [windowEndMs]="window().end"
            />
          </section>
        }
      }
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Close</button>
    </mat-dialog-actions>
  `,
  styles: [
    `
      mat-dialog-content {
        max-height: 72vh;
      }
      .bm-sg-ranges {
        display: flex;
        align-items: center;
        gap: 2px;
        padding-bottom: 6px;
        position: sticky;
        top: 0;
        z-index: 1;
        background: var(--mat-sys-surface-container-high, #262626);
      }
      .bm-sg-range {
        min-width: 0;
        padding: 0 10px;
        font-size: 12.5px;
        opacity: 0.7;
      }
      .bm-sg-range--on {
        opacity: 1;
        font-weight: 600;
        text-decoration: underline;
      }
      .bm-sg-count {
        margin-left: auto;
        font-size: 12px;
        opacity: 0.55;
        font-variant-numeric: tabular-nums;
      }
      .bm-sg-chart {
        border-top: 1px solid var(--bm-hairline, rgba(255, 255, 255, 0.12));
        padding-top: 8px;
      }
      .bm-sg-chart h3 {
        margin: 0 0 2px;
        font-size: 12px;
        text-transform: uppercase;
        letter-spacing: 0.05em;
        opacity: 0.75;
        font-weight: 600;
      }
      .bm-sg-empty {
        padding: 24px 0;
        text-align: center;
        opacity: 0.6;
        font-size: 13px;
      }
    `,
  ],
})
export class ServiceGraphsDialogComponent {
  private agentService = inject(AgentService);
  dialogRef = inject(MatDialogRef<ServiceGraphsDialogComponent>);
  ranges = RANGES;

  hours = signal(24);
  loading = signal(true);
  window = signal<{ start: number; end: number }>({ start: 0, end: 0 });
  charts = signal<{ title: string; series: ChartSeries[] }[]>([]);

  constructor(@Inject(MAT_DIALOG_DATA) public data: ServiceGraphsDialogData) {
    this.hours.set(data.hours || 24);
    this.load();
  }

  setRange(hours: number): void {
    this.hours.set(hours);
    this.load();
  }

  private load(): void {
    this.loading.set(true);
    const specs = serviceGraphSpecs(this.data.serviceName, this.data.serviceMetric, this.data.available);
    const end = Date.now();
    const start = end - this.hours() * 3_600_000;
    this.window.set({ start, end });
    const since = new Date(start).toISOString();

    // One request per distinct metric, however many charts reference it — the
    // bytes charts overlay several metrics and several specs can share one.
    const metrics = [...new Set(specs.flatMap((s) => s.metrics))];
    if (!metrics.length) {
      this.charts.set([]);
      this.loading.set(false);
      return;
    }
    forkJoin(metrics.map((m) => this.agentService.metricSeries(this.data.agentId, m, since))).subscribe({
      next: (results) => {
        const byMetric = new Map<string, MetricPoint[]>();
        metrics.forEach((m, i) => byMetric.set(m, results[i].points));
        this.charts.set(
          specs
            .map((spec) => ({ title: spec.title, series: buildSeries(spec, byMetric) }))
            // A metric can be in the snapshot but have no points in this window
            // (a short range on a long-idle series); drop the panel rather than
            // show a row of "no data" boxes.
            .filter((c) => c.series.some((s) => s.points.length > 0)),
        );
        this.loading.set(false);
      },
      error: () => {
        this.charts.set([]);
        this.loading.set(false);
      },
    });
  }
}

/** Turn one spec into the named lines the chart draws. */
function buildSeries(spec: GraphSpec, byMetric: Map<string, MetricPoint[]>): ChartSeries[] {
  const out: ChartSeries[] = [];
  for (const metric of spec.metrics) {
    let points = byMetric.get(metric) ?? [];
    if (spec.filter) {
      points = points.filter((p) => p.labels?.[spec.filter!.key] === spec.filter!.value);
    }
    if (!spec.splitBy) {
      out.push({ name: spec.metrics.length > 1 ? metric : spec.title, points });
      continue;
    }
    const key = spec.splitBy;
    const byLabel = new Map<string, MetricPoint[]>();
    for (const p of points) {
      const v = String(p.labels?.[key] ?? '');
      if (!byLabel.has(v)) byLabel.set(v, []);
      byLabel.get(v)!.push(p);
    }
    for (const [v, pts] of [...byLabel.entries()].sort(byNumberThenName)) {
      out.push({ name: lineName(key, v, pts), points: pts });
    }
  }
  return out;
}

function byNumberThenName(a: [string, unknown], b: [string, unknown]): number {
  const na = Number(a[0]);
  const nb = Number(b[0]);
  if (!Number.isNaN(na) && !Number.isNaN(nb)) return na - nb;
  return a[0].localeCompare(b[0]);
}

/** Name a fanned-out line. A device that belongs to a guest is named by the
 * guest — on a hypervisor "vm 221101" is the answer being looked for, and the
 * kernel device name alone ("drbd1001") is not. */
function lineName(key: string, value: string, points: MetricPoint[]): string {
  const vm = points.find((p) => p.labels?.['vm'])?.labels?.['vm'];
  if (key === 'device' && vm) return `vm ${vm} (${value})`;
  return `${key} ${value}`;
}

/**
 * Which graphs belong to a service, given what the host actually reports.
 *
 * Ordered deliberately: the metric the check grades comes first, the absolute
 * figures behind it next, breakdowns last — the order you read them in when
 * something is wrong.
 */
function serviceGraphSpecs(name: string, metric: string, available: LatestMetric[]): GraphSpec[] {
  const has = (m: string) => available.some((a) => a.metric === m);
  const keep = (specs: GraphSpec[]) =>
    specs.filter((s) => {
      s.metrics = s.metrics.filter(has);
      return s.metrics.length > 0;
    });

  // A "Disk <mount>" service: every disk metric carrying THIS mount.
  if (name.startsWith('Disk /')) {
    const mount = name.slice('Disk '.length);
    const filter = { key: 'mount', value: mount };
    return keep([
      { title: `Usage % · ${mount}`, metrics: ['disk_used_pct'], filter },
      { title: `Used / total bytes · ${mount}`, metrics: ['disk_used_bytes', 'disk_total_bytes'], filter },
    ]);
  }

  if (name === 'Disk IOPS' || metric === 'disk_iops') {
    return keep([
      { title: 'IOPS · server total', metrics: ['disk_iops'] },
      { title: 'Await ms · server average', metrics: ['disk_await_ms'] },
      { title: 'IOPS per device', metrics: ['disk_iops_device'], splitBy: 'device' },
      { title: 'Await ms per device', metrics: ['disk_await_ms_device'], splitBy: 'device' },
      { title: 'Reads per device', metrics: ['disk_reads_total'], splitBy: 'device' },
      { title: 'Writes per device', metrics: ['disk_writes_total'], splitBy: 'device' },
      { title: 'Bytes read per device', metrics: ['disk_read_bytes_total'], splitBy: 'device' },
      { title: 'Bytes written per device', metrics: ['disk_written_bytes_total'], splitBy: 'device' },
    ]);
  }

  if (name === 'Memory' || metric === 'mem_used_pct') {
    return keep([
      { title: 'Usage %', metrics: ['mem_used_pct'] },
      { title: 'Bytes', metrics: ['mem_used_bytes', 'mem_total_bytes', 'mem_available_bytes', 'mem_cached_bytes', 'mem_free_bytes'] },
      { title: 'Swap %', metrics: ['swap_used_pct'] },
      { title: 'Swap bytes', metrics: ['swap_used_bytes', 'swap_total_bytes'] },
    ]);
  }

  // A per-interface service ("Interface ens18"): the check grades link state,
  // the throughput lives in the agent's net_*_bytes telemetry labelled by iface.
  if (name.startsWith('Interface ')) {
    const filter = { key: 'iface', value: name.slice('Interface '.length) };
    return keep([
      { title: `Received bytes · ${filter.value}`, metrics: ['net_rx_bytes'], filter },
      { title: `Transmitted bytes · ${filter.value}`, metrics: ['net_tx_bytes'], filter },
    ]);
  }

  if (name === 'CPU load' || metric === 'cpu_pct' || metric.startsWith('cpu_load')) {
    return keep([
      { title: 'Load average', metrics: ['cpu_load1', 'cpu_load5', 'cpu_load15'] },
      { title: 'Utilization %', metrics: ['cpu_pct'] },
      { title: 'Utilization % per core', metrics: ['cpu_core_pct'], splitBy: 'core' },
      { title: 'Seconds by mode', metrics: ['cpu_mode_seconds_total'], splitBy: 'mode' },
    ]);
  }

  // Anything else: the graded metric, plus its subsystem siblings. Derived from
  // the snapshot, so a service Bossman gains later needs no entry here.
  const specs: GraphSpec[] = [];
  if (metric) specs.push({ title: metric, metrics: [metric] });
  const prefix = (metric || '').split('_')[0];
  if (prefix) {
    for (const sibling of siblingMetrics(prefix, metric, available)) {
      specs.push({ title: sibling.metric, metrics: [sibling.metric], splitBy: sibling.splitBy });
    }
  }
  return keep(specs);
}

/** Other metrics in the same subsystem, each with the label to fan out by (the
 * first label it carries — device/core/mode/interface all behave the same). */
function siblingMetrics(
  prefix: string,
  exclude: string,
  available: LatestMetric[],
): { metric: string; splitBy?: string }[] {
  const seen = new Map<string, string | undefined>();
  for (const a of available) {
    if (a.metric === exclude || !a.metric.startsWith(prefix + '_')) continue;
    if (a.metric.startsWith('check_')) continue;
    if (!seen.has(a.metric)) {
      const key = Object.keys(a.labels ?? {}).filter((k) => k !== 'vm' && k !== 'volume')[0];
      seen.set(a.metric, key);
    }
  }
  return [...seen.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([metric, splitBy]) => ({ metric, splitBy }));
}
