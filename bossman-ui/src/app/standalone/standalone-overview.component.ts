import { Component, computed, inject, signal, input, OnInit } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { NgxEchartsDirective } from 'ngx-echarts';
import { HostStatusBadgeComponent } from '../shared/components/host-status-badge/host-status-badge.component';

/**
 * Standalone host Overview, in the YOLO-MAN design language (dark Material
 * surfaces, the Rasta tricolour only as an identity rule, green/gold/red used
 * ONLY as status accents — never as a fill). Backed by the agent's own
 * /api/v1/metrics: cpu/load/memory + per-filesystem usage as performance
 * gauges, the built-in check_*_state health checks as a filterable services
 * grid, and any WARN/CRIT check as an alert.
 */
interface Pt { time: string; value: number; }
interface Vital { metric: string; label: string; value: number; unit: string; level: 'crit' | 'warn' | 'ok'; series: Pt[]; }
interface Svc { name: string; state: number; state_label: 'OK' | 'WARN' | 'CRIT' | 'UNKNOWN'; }
type Filter = 'all' | 'crit' | 'warn';

@Component({
  selector: 'app-standalone-overview',
  standalone: true,
  imports: [CommonModule, NgxEchartsDirective, HostStatusBadgeComponent],
  template: `
    <div class="ov-page">
      <div class="ov-head">
        <h1>{{ hostname() }}</h1>
        <span class="ov-sub">host overview</span>
        <span class="ov-spacer"></span>
        @if (live()) { <span class="ov-live"><span class="ov-live-dot"></span>live</span> }
        @else if (loading()) { <span class="ov-loading">loading…</span> }
      </div>

      <!-- PERFORMANCE -->
      <section class="ov-section">
        <div class="ov-section-head">
          <h3>Performance</h3>
          @if (!baseVitals().length && !fsVitals().length && !loading()) { <span class="ov-hint">no metrics yet</span> }
        </div>
        @if (baseVitals().length || fsVitals().length) {
          <div class="gauges-row">
            @for (vital of baseVitals(); track vital.metric) {
              <div class="gauge-cell">
                <div class="gauge-label">{{ vital.label }}</div>
                <div echarts [options]="gaugeOptions(vital)" class="gauge-chart"></div>
                @if (vital.series.length > 1) { <div echarts [options]="sparklineOptions(vital)" class="sparkline-chart"></div> }
              </div>
            }
            @for (vital of fsVitals(); track vital.metric) {
              <div class="gauge-cell">
                <div class="gauge-label">{{ vital.label }}</div>
                <div echarts [options]="gaugeOptions(vital)" class="gauge-chart"></div>
              </div>
            }
          </div>
        } @else if (loading()) { <div class="ov-empty">loading metrics…</div> }
      </section>

      <!-- SERVICES -->
      <section class="ov-section">
        <div class="ov-section-head">
          <h3>Services</h3>
          <div class="ov-filters">
            <button class="bm-chip" [class.on]="filter() === 'all'" (click)="filter.set('all')">All {{ counts().total }}</button>
            <button class="bm-chip" data-st="CRIT" [class.on]="filter() === 'crit'" (click)="filter.set('crit')">CRIT {{ counts().crit }}</button>
            <button class="bm-chip" data-st="WARN" [class.on]="filter() === 'warn'" (click)="filter.set('warn')">WARN {{ counts().warn }}</button>
            <!-- OK is informational only: filtering an overview down to just the
                 healthy services hides the problems you opened it for. -->
            <span class="ov-ok-count">{{ counts().ok }} OK</span>
          </div>
        </div>
        @if (!services().length) { <div class="ov-empty">{{ loading() ? 'loading services…' : 'no health checks' }}</div> }
        @else if (!filteredServices().length) { <div class="ov-empty">no {{ filter() }} services</div> }
        @else {
          <div class="services-grid">
            @for (svc of filteredServices(); track svc.name) {
              <div class="svc-row">
                <app-status-badge [status]="badgeOf(svc.state_label)" [label]="svc.state_label" />
                <span class="svc-name">{{ svc.name }}</span>
              </div>
            }
          </div>
        }
      </section>

      <!-- ALERTS -->
      <section class="ov-section">
        <div class="ov-section-head">
          <h3>Alerts</h3>
          @if (alerts().length) { <span class="ov-count" [class.crit]="counts().crit > 0">{{ alerts().length }}</span> }
        </div>
        @if (!alerts().length) { <div class="ov-empty ov-ok">{{ loading() ? 'loading…' : 'No active alerts — all checks OK.' }}</div> }
        @else {
          @for (a of alerts(); track a.name) {
            <div class="alert-row">
              <app-status-badge [status]="badgeOf(a.state_label)" [label]="a.state_label" />
              <span class="alert-title">{{ a.name }}</span>
            </div>
          }
        }
      </section>
    </div>
  `,
  styles: [`
    :host { display: block; height: 100%; overflow-y: auto; background: var(--mat-sys-surface, #0d0d0d); color: var(--mat-sys-on-surface, #eee); }
    .ov-page { padding: 24px; max-width: 1100px; margin: 0 auto; display: flex; flex-direction: column; gap: 16px; }

    .ov-head { display: flex; align-items: baseline; gap: 12px; padding-bottom: 8px; border-bottom: 3px solid transparent;
      border-image: var(--bm-tricolor, linear-gradient(90deg, #d0021b 0%, #ffc800 50%, #1e9600 100%)) 1; }
    .ov-head h1 { margin: 0; font-size: 22px; font-weight: 700; }
    .ov-sub { font-size: 13px; opacity: .6; text-transform: uppercase; letter-spacing: .05em; }
    .ov-spacer { flex: 1; }
    .ov-live { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; color: var(--bm-green, #1e9600); font-weight: 600; text-transform: uppercase; letter-spacing: .05em; }
    .ov-live-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--bm-green, #1e9600); animation: pulse 2s infinite; }
    .ov-loading { font-size: 12px; opacity: .55; }
    @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: .35; } }

    .ov-section { background: var(--mat-sys-surface-container, #1a1a1a); border: 1px solid var(--mat-sys-outline-variant, #333); border-radius: var(--bm-radius, 8px); overflow: hidden; }
    .ov-section-head { display: flex; align-items: center; gap: 14px; padding: 12px 16px; border-bottom: 1px solid var(--bm-hairline, rgba(255,255,255,.12)); }
    .ov-section-head h3 { margin: 0; font-size: 13px; text-transform: uppercase; letter-spacing: .05em; opacity: .75; font-weight: 600; }
    .ov-hint { font-size: 12px; opacity: .55; }
    .ov-count { font-size: 12px; font-weight: 700; padding: 1px 9px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); font-variant-numeric: tabular-nums; }
    .ov-count.crit { color: var(--bm-red, #d0021b); background: color-mix(in srgb, var(--bm-red, #d0021b) 18%, transparent); }
    .ov-empty { padding: 22px 16px; text-align: center; font-size: 13px; opacity: .55; }
    .ov-empty.ov-ok { color: var(--bm-green, #1e9600); opacity: .85; }

    /* Filter pills — the shared .bm-chip look (fleet-overview idiom). */
    .ov-filters { margin-left: auto; display: flex; gap: 6px; flex-wrap: wrap; }
    .bm-chip { border: 1px solid var(--mat-sys-outline-variant, #333); background: var(--mat-sys-surface, #0d0d0d); color: inherit;
      border-radius: 14px; padding: 3px 12px; font-size: 12.5px; cursor: pointer; font-variant-numeric: tabular-nums; }
    .bm-chip:hover { background: var(--bm-hover, rgba(255,255,255,.06)); }
    .bm-chip.on { background: color-mix(in srgb, var(--mat-sys-primary, #1e9600) 22%, transparent); border-color: var(--mat-sys-primary, #1e9600); font-weight: 600; }
    .bm-chip[data-st='CRIT'].on { background: color-mix(in srgb, var(--bm-red, #d0021b) 26%, transparent); border-color: var(--bm-red, #d0021b); }
    .bm-chip[data-st='WARN'].on { background: color-mix(in srgb, var(--bm-gold, #ffc800) 30%, transparent); border-color: var(--bm-gold, #ffc800); }
    .ov-ok-count { align-self: center; font-size: 12.5px; padding: 0 6px; color: var(--bm-green, #1e9600); font-variant-numeric: tabular-nums; white-space: nowrap; }

    .gauges-row { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 10px; padding: 16px; }
    .gauge-cell { display: flex; flex-direction: column; align-items: center; background: var(--mat-sys-surface-container-high, #262626);
      border: 1px solid var(--bm-hairline, rgba(255,255,255,.12)); border-radius: var(--bm-radius, 8px); padding: 10px 6px 6px; }
    .gauge-label { font-size: 11px; text-transform: uppercase; letter-spacing: .06em; opacity: .7; margin-bottom: 2px; }
    .gauge-chart { width: 100%; height: 120px; } .sparkline-chart { width: 100%; height: 40px; margin-top: -6px; }

    .services-grid { display: grid; grid-template-columns: repeat(2, 1fr); }
    .svc-row { display: flex; align-items: center; gap: 12px; padding: 9px 16px; border-top: 1px solid var(--bm-hairline, rgba(255,255,255,.08)); min-width: 0; }
    .svc-row:nth-child(-n+2) { border-top: none; }
    .svc-name { font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .alert-row { display: flex; align-items: center; gap: 12px; padding: 10px 16px; border-top: 1px solid var(--bm-hairline, rgba(255,255,255,.08)); }
    .alert-row:first-of-type { border-top: none; }
    .alert-title { font-size: 13px; font-weight: 500; }
    @media (max-width: 720px) { .services-grid { grid-template-columns: 1fr; } .svc-row:nth-child(2) { border-top: 1px solid var(--bm-hairline, rgba(255,255,255,.08)); } }
  `],
})
export class StandaloneOverviewComponent implements OnInit {
  private http = inject(HttpClient);
  // Fleet reuse: when an agentId is given the cockpit reads Bossman's
  // per-agent metrics endpoint; left empty (standalone console) it reads the
  // agent's own same-origin /api/v1/metrics. hostName overrides the title.
  agentId = input<string>('');
  hostName = input<string>('');
  loading = signal(true);
  live = signal(false);
  hostname = signal('');
  filter = signal<Filter>('all');
  private metrics = signal<Record<string, { timestamp: string; value: number; labels?: Record<string, string> }[]>>({});
  private cpuCount = 4;

  ngOnInit(): void {
    this.hostname.set(this.hostName() || location.hostname);
    this.load();
    setInterval(() => this.load(true), 15000);
  }

  private load(quiet = false): void {
    if (!quiet) this.loading.set(true);
    // Standalone: the agent's own /metrics returns {metrics:{name:[points…]}}.
    // Fleet: Bossman's /agents/<id>/metrics/latest returns the newest sample of
    // every metric as a flat list [{metric,time,value,labels}] — reshape it to
    // the same {name:[point]} map so the computeds below don't care which shell.
    const url = this.agentId() ? `/api/v1/agents/${this.agentId()}/metrics/snapshot` : '/api/v1/metrics';
    type Pt = { timestamp: string; value: number; labels?: Record<string, string> };
    type LatestRow = { metric: string; time: string; value: number; labels?: Record<string, string> };
    this.http.get<{ metrics: Record<string, Pt[]> | LatestRow[] }>(url).subscribe({
      next: (r) => {
        this.loading.set(false); this.live.set(true);
        const raw = r.metrics;
        let m: Record<string, Pt[]>;
        if (Array.isArray(raw)) {
          m = {};
          for (const x of raw) { (m[x.metric] ||= []).push({ timestamp: x.time, value: x.value, labels: x.labels }); }
        } else {
          m = raw || {};
        }
        this.metrics.set(m);
        const cc = this.latest(m['cpu_count']); if (cc) this.cpuCount = cc;
      },
      error: () => { this.loading.set(false); this.live.set(false); },
    });
  }

  private latest(series?: { value: number }[]): number | null {
    if (!series || !series.length) return null;
    return series[series.length - 1].value;
  }
  private pct(v: number): 'crit' | 'warn' | 'ok' { return v >= 90 ? 'crit' : v >= 75 ? 'warn' : 'ok'; }

  baseVitals = computed<Vital[]>(() => {
    const m = this.metrics();
    const out: Vital[] = [];
    const mk = (metric: string, label: string, unit: string, level: (v: number) => 'crit' | 'warn' | 'ok') => {
      const s = m[metric]; const v = this.latest(s); if (v == null) return;
      out.push({ metric, label, unit, value: Math.round(v * 10) / 10, level: level(v), series: (s || []).slice(-60).map((p) => ({ time: p.timestamp, value: p.value })) });
    };
    mk('cpu_pct', 'CPU', '%', (v) => this.pct(v));
    mk('mem_used_pct', 'Memory', '%', (v) => this.pct(v));
    mk('cpu_load1', 'Load', '', (v) => (v >= this.cpuCount ? 'crit' : v >= this.cpuCount * 0.7 ? 'warn' : 'ok'));
    return out;
  });

  fsVitals = computed<Vital[]>(() => {
    const s = this.metrics()['disk_used_pct'] || [];
    const byMount = new Map<string, number>();
    for (const p of s) { const mnt = p.labels?.['mount'] || p.labels?.['mountpoint'] || p.labels?.['path'] || '/'; byMount.set(mnt, p.value); }
    return [...byMount.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([mnt, v]) => ({
      metric: 'fs:' + mnt, label: mnt, unit: '%', value: Math.round(v * 10) / 10, level: this.pct(v), series: [],
    }));
  });

  services = computed<Svc[]>(() => {
    const m = this.metrics();
    const labels: Record<number, Svc['state_label']> = { 0: 'OK', 1: 'WARN', 2: 'CRIT', 3: 'UNKNOWN' };
    const out: Svc[] = [];
    for (const name of Object.keys(m)) {
      if (!name.startsWith('check_') || !name.endsWith('_state')) continue;
      const v = this.latest(m[name]); if (v == null) continue;
      const st = Math.round(v);
      const pretty = name.replace(/^check_/, '').replace(/_state$/, '').replace(/__+/g, ' /').replace(/_/g, ' ').trim();
      out.push({ name: pretty, state: st, state_label: labels[st] || 'UNKNOWN' });
    }
    return out.sort((a, b) => b.state - a.state || a.name.localeCompare(b.name));
  });

  filteredServices = computed<Svc[]>(() => {
    const f = this.filter();
    if (f === 'all') return this.services();
    const want = f === 'crit' ? 2 : 1;
    return this.services().filter((s) => s.state === want);
  });

  alerts = computed<Svc[]>(() => this.services().filter((s) => s.state === 1 || s.state === 2));

  counts = computed(() => {
    const s = this.services();
    return { total: s.length, crit: s.filter((x) => x.state === 2).length, warn: s.filter((x) => x.state === 1).length, ok: s.filter((x) => x.state === 0).length };
  });

  badgeOf(l: string): 'ok' | 'warn' | 'crit' | 'unknown' {
    return l === 'CRIT' ? 'crit' : l === 'WARN' ? 'warn' : l === 'OK' ? 'ok' : 'unknown';
  }

  gaugeOptions(vital: Vital) {
    const color = vital.level === 'crit' ? '#d0021b' : vital.level === 'warn' ? '#ffc800' : '#1e9600';
    const max = vital.metric === 'cpu_load1' ? Math.max(8, this.cpuCount * 2) : 100;
    return {
      backgroundColor: 'transparent',
      series: [{
        type: 'gauge', center: ['50%', '52%'], radius: '80%', startAngle: 210, endAngle: -30, min: 0, max, splitNumber: 5,
        axisLine: { lineStyle: { width: 9, color: [[vital.value / max, color], [1, 'rgba(255,255,255,0.10)']] } },
        pointer: { length: '52%', width: 3, itemStyle: { color } },
        axisTick: { show: false }, splitLine: { show: false }, axisLabel: { show: false },
        detail: { formatter: `{value}${vital.unit}`, color: '#e8e8e8', fontSize: 17, fontWeight: 'bold', offsetCenter: [0, '58%'] },
        title: { show: false }, data: [{ value: vital.value, name: vital.label }],
      }],
    };
  }

  sparklineOptions(vital: Vital) {
    const color = vital.level === 'crit' ? '#d0021b' : vital.level === 'warn' ? '#ffc800' : '#1e9600';
    return {
      backgroundColor: 'transparent', grid: { left: 0, right: 0, top: 2, bottom: 0 },
      xAxis: { type: 'category' as const, show: false, data: vital.series.map((p) => p.time), boundaryGap: false },
      yAxis: { type: 'value' as const, show: false },
      series: [{ type: 'line' as const, smooth: true, showSymbol: false, lineStyle: { width: 1.5, color }, areaStyle: { color, opacity: 0.12 }, data: vital.series.map((p) => p.value) }],
    };
  }
}
