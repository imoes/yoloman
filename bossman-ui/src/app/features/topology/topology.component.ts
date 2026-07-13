import { Component, NgZone, OnDestroy, OnInit, computed, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { Router } from '@angular/router';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { NgxEchartsDirective } from 'ngx-echarts';
import { environment } from '../../../environments/environment';

interface TopoNode { id: string; label: string; type: string; status: string; alert_count: number; inactive: boolean; }
interface TopoEdge { source: string; target: string; kind: string; label?: string; events?: number; latency_ms?: number | null; p99?: number | null; status?: string; }
interface TopoGraph { nodes: TopoNode[]; edges: TopoEdge[]; stats?: { hosts: number; edges: number; alerts: number }; error?: string; }

const SEV_COLOR: Record<string, string> = {
  critical: '#d32f2f', high: '#e65100', medium: '#caa300', low: '#607d8b', ok: '#2e7d32',
};
const NODE_SIZE: Record<string, number> = { proxy: 26, host: 16 };
const CATS = ['proxy', 'host'];

/**
 * Infrastructure map (CentralStation-style): hosts as nodes, eBPF-derived
 * relationships (host_edges) as edges. ECharts force graph — node color by
 * CheckMK state rollup, size by type, dashed orange for structural parent
 * (proxy→satellite) edges. Error/empty states, search filter, refresh (the
 * backend caches the graph). Standalone /topology page; also embedded in a
 * host's Relationships tab (pass [agentId] to spotlight it).
 */
@Component({
  selector: 'app-topology',
  standalone: true,
  imports: [FormsModule, MatIconModule, MatButtonModule, MatProgressSpinnerModule, NgxEchartsDirective],
  template: `
    <div class="bm-topo">
      <div class="bm-topo-bar">
        <h2 class="bm-topo-title"><mat-icon>account_tree</mat-icon> Infrastructure map</h2>
        @if (graph()?.stats; as s) {
          <span class="bm-chip">{{ s.hosts }} hosts</span>
          <span class="bm-chip">{{ s.edges }} edges</span>
          @if (s.alerts > 0) { <span class="bm-chip bm-chip-alert">{{ s.alerts }} alerts</span> }
        }
        <span class="bm-spacer"></span>
        <input class="bm-topo-search" type="text" [ngModel]="search()" (ngModelChange)="search.set($event.toLowerCase())" placeholder="Filter nodes…" />
        <button mat-stroked-button (click)="load(true)" [disabled]="loading()">
          @if (loading()) { <mat-spinner diameter="16" /> } @else { <mat-icon>refresh</mat-icon> } Refresh
        </button>
      </div>

      @if (graph()?.error) {
        <div class="bm-topo-empty"><mat-icon>lan</mat-icon><p>{{ graph()!.error }}</p></div>
      } @else if (loading() && !graph()) {
        <div class="bm-topo-empty"><mat-spinner diameter="40" /><p>Loading infrastructure…</p></div>
      } @else if (graph()?.nodes?.length === 0) {
        <div class="bm-topo-empty"><mat-icon>hub</mat-icon><p>No hosts enrolled yet.</p></div>
      } @else {
        <div echarts [options]="options()" class="bm-topo-chart"
             (chartInit)="onInit($event)" (chartClick)="onClick($event)"></div>
      }
    </div>
  `,
  styles: [`
    :host { display: block; height: 100%; }
    .bm-topo { display: flex; flex-direction: column; height: 100%; min-height: 480px; }
    .bm-topo-bar { display: flex; align-items: center; gap: 10px; padding: 8px 4px 12px; flex-wrap: wrap; }
    .bm-topo-title { display: flex; align-items: center; gap: 6px; margin: 0; font-size: 1.05rem; font-weight: 600; }
    .bm-spacer { flex: 1; }
    .bm-chip { padding: 2px 10px; border-radius: 12px; font-size: 12px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-chip-alert { background: color-mix(in srgb, var(--bm-red, #d32f2f) 22%, transparent); color: var(--bm-red, #d32f2f); }
    .bm-topo-search { padding: 5px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; width: 200px; }
    .bm-topo-chart { flex: 1; min-height: 0; width: 100%; }
    .bm-topo-empty { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 12px; opacity: 0.6; }
    .bm-topo-empty mat-icon { font-size: 44px; width: 44px; height: 44px; opacity: 0.5; }
  `],
})
export class TopologyComponent implements OnInit, OnDestroy {
  private http = inject(HttpClient);
  private router = inject(Router);
  private zone = inject(NgZone);
  /** When embedded in a host's Relationships tab, the host to spotlight. */
  agentId = input<string | undefined>(undefined);

  graph = signal<TopoGraph | null>(null);
  loading = signal(true);
  search = signal('');
  private echart: unknown = null;
  private resizeObs: ResizeObserver | null = null;

  private dark = matchMedia('(prefers-color-scheme: dark)').matches;
  private get txt() { return this.dark ? '#cbd5e1' : '#475569'; }
  private get grid() { return this.dark ? '#475569' : '#94a3b8'; }

  options = computed(() => {
    const g = this.graph();
    if (!g || !g.nodes?.length) return {};
    const term = this.search();
    const spotlight = this.agentId();
    return {
      backgroundColor: 'transparent',
      tooltip: {
        formatter: (p: { dataType: string; data: Record<string, unknown> }) =>
          p.dataType === 'node'
            ? `<b>${p.data['name']}</b><br/>${p.data['nodeType']} · ${p.data['status']} · ${p.data['alertCount']} alerts`
            : p.data['kind'] === 'parent'
              ? `${p.data['source']} → ${p.data['target']}<br/>proxy → satellite`
              : `${p.data['source']} → ${p.data['target']}`
                + (p.data['label'] ? '<br/>ports: ' + p.data['label'] : '')
                + '<br/>connects: ' + (p.data['events'] ?? 0)
                + (p.data['latency'] != null ? '<br/>latency (p50): ' + p.data['latency'] + ' ms' : '')
                + (p.data['p99'] != null ? '<br/>p99: ' + p.data['p99'] + ' ms' : ''),
      },
      legend: { data: CATS, textStyle: { color: this.txt }, bottom: 2 },
      series: [{
        type: 'graph', layout: 'force', roam: true, draggable: true,
        categories: CATS.map((c) => ({ name: c })),
        force: { repulsion: 220, edgeLength: [60, 160], gravity: 0.08 },
        label: { show: true, position: 'right', fontSize: 11, color: this.txt, formatter: (p: { data: { name: string } }) => p.data.name.split('.')[0] },
        labelLayout: { hideOverlap: true },
        emphasis: { focus: 'adjacency', label: { show: true } },
        lineStyle: { color: this.grid, width: 1.5, curveness: 0.08 },
        data: g.nodes.map((n) => ({
          id: n.id, name: n.label, category: Math.max(0, CATS.indexOf(n.type)),
          nodeType: n.type, status: n.status, alertCount: n.alert_count,
          symbolSize: (NODE_SIZE[n.type] ?? 16) + Math.min(n.alert_count * 1.5, 10),
          itemStyle: {
            color: SEV_COLOR[n.status] ?? SEV_COLOR['ok'],
            borderColor: spotlight && n.id === spotlight ? '#4fd6ff' : 'transparent',
            borderWidth: spotlight && n.id === spotlight ? 3 : 0,
            opacity: term && !n.label.toLowerCase().includes(term) ? 0.15 : (n.inactive ? 0.4 : 1),
          },
        })),
        links: g.edges.map((e) => ({
          source: e.source, target: e.target, kind: e.kind,
          events: e.events, latency: e.latency_ms, p99: e.p99,
          // Connection edges: label the latency (Coroot-style), color by health,
          // width by connection volume. Parent edges stay dashed orange.
          label: e.kind === 'connection'
            ? { show: e.latency_ms != null, formatter: e.latency_ms != null ? `${e.latency_ms} ms` : '', fontSize: 10, color: this.txt }
            : undefined,
          lineStyle: e.kind === 'parent'
            ? { type: 'dashed', color: '#e65100', width: 2 }
            : { color: SEV_COLOR[e.status ?? 'ok'] ?? this.grid, width: Math.min(1.5 + Math.log10((e.events ?? 0) + 1), 6), curveness: 0.08, opacity: 0.85 },
        })),
      }],
    };
  });

  ngOnInit(): void { this.load(false); }
  ngOnDestroy(): void { this.resizeObs?.disconnect(); }

  onInit(ec: unknown): void {
    this.echart = ec;
    this.zone.runOutsideAngular(() => {
      setTimeout(() => (ec as { resize: () => void }).resize(), 0);
      if (typeof ResizeObserver !== 'undefined') {
        const el = (ec as { getDom: () => HTMLElement }).getDom();
        this.resizeObs?.disconnect();
        this.resizeObs = new ResizeObserver(() => (ec as { resize: () => void }).resize());
        this.resizeObs.observe(el);
      }
    });
  }

  load(refresh: boolean): void {
    this.loading.set(true);
    this.http.get<TopoGraph>(`${environment.apiUrl}/topology/graph${refresh ? '?refresh=true' : ''}`).subscribe({
      next: (g) => { this.graph.set(g); this.loading.set(false); setTimeout(() => (this.echart as { resize: () => void } | null)?.resize(), 50); },
      error: () => this.loading.set(false),
    });
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  onClick(event: any): void {
    if (event?.dataType === 'node' && event?.data?.id) {
      this.router.navigate(['/hosts', event.data.id]);
    }
  }
}
