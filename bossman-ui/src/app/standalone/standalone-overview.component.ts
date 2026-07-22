import { Component, computed, inject, signal, OnInit } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { NgxEchartsDirective } from 'ngx-echarts';

/**
 * Standalone host Overview — the CentralStation "Cockpit" look (LCARS caps,
 * gauge cells with sparklines, a services grid, an alerts list), backed by the
 * agent's own /api/v1/metrics: cpu/load/memory + per-filesystem usage as
 * vitals, the built-in check_*_state health checks as services, and any
 * WARN/CRIT check as an alert.
 */
interface Pt { time: string; value: number; }
interface Vital { metric: string; label: string; value: number; unit: string; level: 'crit' | 'high' | 'ok'; series: Pt[]; }
interface Svc { name: string; state: number; state_label: 'OK' | 'WARN' | 'CRIT' | 'UNKNOWN'; summary: string; }

@Component({
  selector: 'app-standalone-overview',
  standalone: true,
  imports: [CommonModule, NgxEchartsDirective],
  template: `
    <div class="cap-bar top">
      <div class="cap-tl"></div>
      <span class="cap-title">COCKPIT&nbsp;—&nbsp;{{ hostname() }}</span>
      <div class="cap-spacer"></div>
      @if (live()) { <span class="badge-live">LIVE ●</span> } @else if (loading()) { <span class="badge-loading">INIT…</span> }
      <div class="cap-tr"></div>
    </div>

    <div class="cockpit-body">
      <div class="block">
        <div class="block-head"><span>PERFORMANCE</span>
          @if (!baseVitals().length && !fsVitals().length && !loading()) { <span class="block-hint">no metrics yet</span> }
        </div>
        @if (baseVitals().length || fsVitals().length) {
          <div class="gauges-row">
            @for (vital of baseVitals(); track vital.metric) {
              <div class="gauge-cell">
                <div class="gauge-label">{{ vital.label }}</div>
                <div echarts [options]="gaugeOptions(vital)" class="gauge-chart"></div>
                @if (vital.series.length > 1) { <div echarts [options]="sparklineOptions(vital)" class="sparkline-chart"></div> }
                <div class="gauge-meta">
                  <span class="gauge-value" [attr.data-level]="vital.level">{{ vital.value }}{{ vital.unit }}</span>
                  <span class="gauge-level" [attr.data-level]="vital.level">{{ vital.level.toUpperCase() }}</span>
                </div>
              </div>
            }
            @for (vital of fsVitals(); track vital.metric) {
              <div class="gauge-cell">
                <div class="gauge-label">{{ vital.label }}</div>
                <div echarts [options]="gaugeOptions(vital)" class="gauge-chart"></div>
                <div class="gauge-meta">
                  <span class="gauge-value" [attr.data-level]="vital.level">{{ vital.value }}{{ vital.unit }}</span>
                  <span class="gauge-level" [attr.data-level]="vital.level">{{ vital.level.toUpperCase() }}</span>
                </div>
              </div>
            }
          </div>
        } @else if (loading()) { <div class="block-loading">loading metrics…</div> }
      </div>

      <div class="block">
        <div class="block-head"><span>SERVICES</span>
          <span class="block-count">{{ counts().total }}</span>
          @if (counts().crit > 0) { <span class="count-pill crit">{{ counts().crit }} CRIT</span> }
          @if (counts().warn > 0) { <span class="count-pill warn">{{ counts().warn }} WARN</span> }
          <span class="count-pill ok">{{ counts().ok }} OK</span>
        </div>
        <div class="services-area">
          @if (!services().length) { <div class="alert-empty">{{ loading() ? 'loading services…' : 'no health checks' }}</div> }
          @else {
            <div class="services-grid">
              @for (svc of services(); track svc.name) {
                <div class="svc-cell">
                  <div class="svc-row">
                    <span class="svc-dot" [style.background]="svcColor(svc.state_label)"></span>
                    <span class="svc-state" [style.color]="svcColor(svc.state_label)">{{ svc.state_label }}</span>
                    <div class="svc-info">
                      <span class="svc-name">{{ svc.name }}</span>
                      @if (svc.summary) { <span class="svc-summary">{{ svc.summary }}</span> }
                    </div>
                  </div>
                </div>
              }
            </div>
          }
        </div>
      </div>

      <div class="block">
        <div class="block-head blue"><span>ALERTS</span><span class="block-count">{{ alerts().length }}</span></div>
        <div class="alert-list">
          @if (!alerts().length) { <div class="alert-empty">{{ loading() ? 'loading…' : 'no active alerts' }}</div> }
          @for (a of alerts(); track a.name) {
            <div class="alert-row">
              <span class="sev-dot" [style.background]="svcColor(a.state_label)"></span>
              <span class="alert-severity">{{ a.state_label }}</span>
              <span class="alert-title">{{ a.name }}</span>
              <span class="alert-source">{{ a.summary }}</span>
            </div>
          }
        </div>
      </div>
    </div>

    <div class="cap-bar bottom">
      <div class="cap-bl"></div>
      <span class="cap-bottom-label">AGENT SELF-MONITOR</span>
      <div class="cap-spacer"></div>
      <span class="cap-host-id">{{ hostname() }}</span>
      <div class="cap-br"></div>
    </div>
  `,
  styles: [`
    :host { display: flex; flex-direction: column; height: 100%; min-height: 70vh; overflow: hidden; background: #000; color: #ffe8a0; font-family: Roboto, 'Helvetica Neue', sans-serif; }
    .cap-bar { background: #FF9933; color: #000; font-weight: 700; font-size: 14px; letter-spacing: .1em; text-transform: uppercase; display: flex; align-items: center; gap: 10px; padding: 0 0 0 4px; height: 32px; flex-shrink: 0; }
    .cap-bar.bottom { height: 28px; font-size: 11px; }
    .cap-tl { width: 32px; height: 32px; background: #000; flex-shrink: 0; }
    .cap-tr { width: 20px; height: 32px; background: #000; flex-shrink: 0; }
    .cap-bl { width: 20px; height: 28px; background: #000; border-radius: 0 0 0 18px; flex-shrink: 0; }
    .cap-br { width: 20px; height: 28px; background: #000; border-radius: 0 0 18px 0; flex-shrink: 0; }
    .cap-title { font-size: 16px; font-weight: 700; letter-spacing: .12em; white-space: nowrap; }
    .cap-spacer { flex: 1; } .cap-host-id { font-size: 11px; opacity: .7; } .cap-bottom-label { font-size: 11px; }
    .badge-live { background: #000; color: #66cc66; font-size: 11px; padding: 2px 10px; border-radius: 99px; font-weight: 700; letter-spacing: .06em; animation: pulse 2s infinite; }
    .badge-loading { background: #000; color: #ffcc66; font-size: 11px; padding: 2px 10px; border-radius: 99px; }
    @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: .5; } }
    .cockpit-body { flex: 1; min-height: 0; overflow-y: auto; padding: 12px 16px 16px; display: flex; flex-direction: column; gap: 12px; }
    .block { background: #0a0804; border: 1px solid #3a2810; border-radius: 0 12px 12px 12px; overflow: hidden; }
    .block-head { background: #FF9933; color: #000; padding: 5px 14px; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; font-size: 13px; display: flex; align-items: center; gap: 10px; }
    .block-head.blue { background: #99CCFF; }
    .block-count { background: #000; color: #99CCFF; font-size: 11px; padding: 1px 8px; border-radius: 99px; }
    .block-hint { font-size: 11px; opacity: .65; }
    .block-loading { padding: 28px 16px; color: #e8a060; font-size: 12px; letter-spacing: .08em; text-align: center; }
    .gauges-row { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 8px; padding: 12px 16px; }
    .gauge-cell { display: flex; flex-direction: column; align-items: center; background: #0f0c08; border: 1px solid #2a1d0a; border-radius: 8px; padding: 8px 4px 6px; }
    .gauge-label { font-size: 10px; color: #FFCC99; text-transform: uppercase; letter-spacing: .1em; margin-bottom: 2px; }
    .gauge-chart { width: 100%; height: 130px; } .sparkline-chart { width: 100%; height: 46px; margin-top: -8px; }
    .gauge-meta { display: flex; gap: 8px; align-items: center; margin-top: 4px; }
    .gauge-value { font-size: 15px; font-weight: 700; color: #ffe8a0; }
    .gauge-value[data-level="crit"] { color: #ff4433; } .gauge-value[data-level="high"] { color: #ffcc00; } .gauge-value[data-level="ok"] { color: #66cc66; }
    .gauge-level { font-size: 9px; padding: 1px 6px; border-radius: 3px; background: #1a1208; letter-spacing: .06em; }
    .gauge-level[data-level="crit"] { color: #ff4433; border: 1px solid #ff4433; } .gauge-level[data-level="high"] { color: #ffcc00; border: 1px solid #ffcc00; } .gauge-level[data-level="ok"] { color: #66cc66; border: 1px solid #66cc66; }
    .count-pill { font-size: 10px; font-weight: 700; padding: 1px 8px; border-radius: 99px; background: #000; letter-spacing: .04em; }
    .count-pill.crit { color: #ff4433; } .count-pill.warn { color: #ffcc00; } .count-pill.ok { color: #66cc66; }
    .services-area { max-height: 52vh; overflow-y: auto; }
    .services-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 1px; padding: 6px; }
    .svc-cell { background: #0f0c08; border: 1px solid #1e1710; min-width: 0; overflow: hidden; }
    .svc-row { display: flex; align-items: flex-start; gap: 8px; padding: 6px 10px; }
    .svc-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; margin-top: 3px; }
    .svc-state { font-size: 9px; font-weight: 700; letter-spacing: .04em; width: 48px; flex-shrink: 0; padding-top: 1px; }
    .svc-info { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
    .svc-name { font-size: 12px; font-weight: 600; color: #ffe8a0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .svc-summary { font-size: 11px; color: #e8a060; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .alert-list { max-height: 42vh; overflow-y: auto; }
    .alert-empty { padding: 20px 16px; color: #5a3a18; font-size: 12px; letter-spacing: .06em; text-align: center; }
    .alert-row { display: flex; align-items: center; gap: 8px; padding: 7px 14px; border-bottom: 1px solid #1e1710; }
    .sev-dot { width: 7px; height: 7px; border-radius: 50%; flex-shrink: 0; }
    .alert-severity { font-size: 9px; font-weight: 700; letter-spacing: .06em; color: #e8a060; width: 60px; flex-shrink: 0; }
    .alert-title { flex: 1; font-size: 12px; color: #ffe8a0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .alert-source { font-size: 10px; color: #FFCC99; text-align: right; }
  `],
})
export class StandaloneOverviewComponent implements OnInit {
  private http = inject(HttpClient);
  loading = signal(true);
  live = signal(false);
  hostname = signal('');
  private metrics = signal<Record<string, { timestamp: string; value: number; labels?: Record<string, string> }[]>>({});
  private cpuCount = 4;

  ngOnInit(): void { this.load(); setInterval(() => this.load(true), 15000); }

  private load(quiet = false): void {
    if (!quiet) this.loading.set(true);
    this.http.get<{ metrics: Record<string, { timestamp: string; value: number; labels?: Record<string, string> }[]> }>('/api/v1/metrics').subscribe({
      next: (r) => {
        this.loading.set(false); this.live.set(true);
        const m = r.metrics || {};
        this.metrics.set(m);
        const cc = this.latest(m['cpu_count']); if (cc) this.cpuCount = cc;
      },
      error: () => { this.loading.set(false); this.live.set(false); },
    });
    this.http.get<{ data?: { ansible_hostname?: string; ansible_fqdn?: string } }>('/api/v1/network').subscribe({ next: () => {}, error: () => {} });
    if (!this.hostname()) this.hostname.set(location.hostname);
  }

  private latest(series?: { value: number }[]): number | null {
    if (!series || !series.length) return null;
    return series[series.length - 1].value;
  }
  private pct(v: number): 'crit' | 'high' | 'ok' { return v >= 90 ? 'crit' : v >= 75 ? 'high' : 'ok'; }

  baseVitals = computed<Vital[]>(() => {
    const m = this.metrics();
    const out: Vital[] = [];
    const mk = (metric: string, label: string, unit: string, level: (v: number) => 'crit' | 'high' | 'ok') => {
      const s = m[metric]; const v = this.latest(s); if (v == null) return;
      out.push({ metric, label, unit, value: Math.round(v * 10) / 10, level: level(v), series: (s || []).slice(-60).map((p) => ({ time: p.timestamp, value: p.value })) });
    };
    mk('cpu_pct', 'CPU', '%', (v) => this.pct(v));
    mk('mem_used_pct', 'Memory', '%', (v) => this.pct(v));
    mk('cpu_load1', 'Load', '', (v) => (v >= this.cpuCount ? 'crit' : v >= this.cpuCount * 0.7 ? 'high' : 'ok'));
    return out;
  });

  fsVitals = computed<Vital[]>(() => {
    const s = this.metrics()['disk_used_pct'] || [];
    // latest value per mount (from the label), newest wins.
    const byMount = new Map<string, number>();
    for (const p of s) { const mnt = p.labels?.['mount'] || p.labels?.['mountpoint'] || p.labels?.['path'] || '/'; byMount.set(mnt, p.value); }
    return [...byMount.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([mnt, v]) => ({
      metric: 'fs:' + mnt, label: 'FS ' + mnt, unit: '%', value: Math.round(v * 10) / 10, level: this.pct(v), series: [],
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
      out.push({ name: pretty, state: st, state_label: labels[st] || 'UNKNOWN', summary: '' });
    }
    return out.sort((a, b) => b.state - a.state || a.name.localeCompare(b.name));
  });

  alerts = computed<Svc[]>(() => this.services().filter((s) => s.state === 1 || s.state === 2));

  counts = computed(() => {
    const s = this.services();
    return { total: s.length, crit: s.filter((x) => x.state === 2).length, warn: s.filter((x) => x.state === 1).length, ok: s.filter((x) => x.state === 0).length };
  });

  svcColor(l: string): string { return l === 'CRIT' ? '#ff4433' : l === 'WARN' ? '#ffcc00' : l === 'OK' ? '#66cc66' : '#888'; }

  gaugeOptions(vital: Vital) {
    const color = vital.level === 'crit' ? '#ff4433' : vital.level === 'high' ? '#ffcc00' : '#66cc66';
    const max = vital.metric === 'cpu_load1' ? 16 : 100;
    return {
      backgroundColor: 'transparent',
      series: [{
        type: 'gauge', center: ['50%', '45%'], radius: '82%', startAngle: 210, endAngle: -30, min: 0, max, splitNumber: 5,
        axisLine: { lineStyle: { width: 10, color: [[vital.value / max, color], [1, '#1e1710']] } },
        pointer: { length: '55%', width: 4, itemStyle: { color } },
        axisTick: { show: false }, splitLine: { show: false }, axisLabel: { show: false },
        detail: { formatter: `{value}${vital.unit}`, color, fontSize: 18, fontWeight: 'bold', offsetCenter: [0, '60%'] },
        title: { show: false }, data: [{ value: vital.value, name: vital.label }],
      }],
    };
  }

  sparklineOptions(vital: Vital) {
    const color = vital.level === 'crit' ? '#ff4433' : vital.level === 'high' ? '#ffcc00' : '#66cc66';
    return {
      backgroundColor: 'transparent', grid: { left: 0, right: 0, top: 2, bottom: 0 },
      xAxis: { type: 'category' as const, show: false, data: vital.series.map((p) => p.time), boundaryGap: false },
      yAxis: { type: 'value' as const, show: false },
      series: [{ type: 'line' as const, smooth: true, showSymbol: false, lineStyle: { width: 1.5, color }, areaStyle: { color, opacity: 0.12 }, data: vital.series.map((p) => p.value) }],
    };
  }
}
