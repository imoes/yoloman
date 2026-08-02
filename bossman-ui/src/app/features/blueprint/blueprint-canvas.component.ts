import {
  AfterViewInit, Component, ElementRef, OnDestroy, effect, inject, input, output, signal, viewChild,
} from '@angular/core';
import cytoscape from 'cytoscape';
import dagre from 'cytoscape-dagre';
import { BM_GOLD, BM_GREEN, BM_UNKNOWN } from '../../shared/bm-colors';
import { Blueprint } from './compose-model';
import { ICON_KEYS, PALETTE } from './compose-model';
import { iconFor, preloadIcons } from './blueprint-icons';

cytoscape.use(dagre);

const NODE_COLOUR = '#d8d8d8';
const EDGE_COLOUR = BM_UNKNOWN;

/**
 * The blueprint canvas — nodes are compose services, edges are `depends_on`.
 *
 * Editing without a new dependency: `cytoscape-edgehandles` is not installed, so
 * "connect" is a MODE — click the source, click the target. That is also friendlier
 * on a trackpad than dragging a hair-thin handle, and it keeps the bundle as-is.
 *
 * Positions are read back out of Cytoscape on drag (`position` event) and pushed
 * into the blueprint, which is what makes the layout survive a reload — the
 * document stores them in `x-yolo-layout`.
 */
@Component({
  selector: 'app-blueprint-canvas',
  standalone: true,
  template: `
    <div class="bm-bpc-wrap">
      <div class="bm-bpc-bar">
        <button type="button" class="bm-bpc-btn" [class.on]="connectMode()"
                (click)="toggleConnect()" title="Connect two services (depends_on)">
          {{ connectMode() ? (pending() ? 'Pick target…' : 'Pick source…') : 'Connect' }}
        </button>
        <button type="button" class="bm-bpc-btn" (click)="autoLayout()" title="Arrange by dependencies">Arrange</button>
        <button type="button" class="bm-bpc-btn" (click)="fit()">Fit</button>
        <span class="bm-bpc-hint">
          @if (connectMode()) { Click the source, then the target · Esc cancels }
          @else { Drag a component here from the left · Click = select · Double-click = delete · Click an edge = variables }
        </span>
      </div>
      <div class="bm-bpc" #host
           [class.dropping]="dropHover()"
           (dragover)="onDragOver($event)"
           (dragleave)="dropHover.set(false)"
           (drop)="onDrop($event)"></div>
    </div>
  `,
  styles: [`
    .bm-bpc-wrap { display: flex; flex-direction: column; height: 100%; min-height: 560px; }
    .bm-bpc-bar { display: flex; align-items: center; gap: 8px; padding: 0 0 8px; flex-wrap: wrap; }
    .bm-bpc-btn { font-size: 12px; padding: 4px 12px; border-radius: 999px; cursor: pointer;
      border: 1px solid var(--mat-sys-outline-variant); background: transparent; color: inherit; }
    .bm-bpc-btn.on { background: color-mix(in srgb, var(--bm-green, #1e9600) 22%, transparent);
      border-color: var(--bm-green, #1e9600); }
    .bm-bpc-hint { font-size: 11.5px; opacity: .55; }
    .bm-bpc { flex: 1 1 auto; min-height: 520px; border: 1px solid var(--mat-sys-outline-variant);
      border-radius: 10px; background: color-mix(in srgb, var(--mat-sys-on-surface) 3%, transparent);
      transition: border-color .12s, background .12s; }
    .bm-bpc.dropping { border-color: var(--bm-green, #1e9600); border-style: dashed;
      background: color-mix(in srgb, var(--bm-green, #1e9600) 8%, transparent); }
  `],
})
export class BlueprintCanvasComponent implements AfterViewInit, OnDestroy {
  private hostRef = viewChild.required<ElementRef<HTMLElement>>('host');

  blueprint = input.required<Blueprint>();
  selected = input<string | null>(null);

  select = output<string | null>();
  selectEdge = output<{ from: string; to: string } | null>();
  /** a palette component was dropped at these MODEL coordinates */
  dropped = output<{ icon: string; x: number; y: number }>();
  connectPair = output<{ from: string; to: string }>();
  moved = output<{ name: string; x: number; y: number }>();
  removeNode = output<string>();

  connectMode = signal(false);
  pending = signal<string | null>(null);
  dropHover = signal(false);

  private cy: cytoscape.Core | null = null;
  private ready = signal(false);

  constructor() {
    // Re-render whenever the document changes (add/remove/rename/connect) — but
    // only once the canvas exists and the icons are loaded.
    effect(() => {
      const bp = this.blueprint();
      const sel = this.selected();
      if (!this.ready()) return;
      this.sync(bp, sel);
    });
  }

  async ngAfterViewInit(): Promise<void> {
    await preloadIcons(ICON_KEYS);
    this.cy = cytoscape({
      container: this.hostRef().nativeElement,
      style: [
        {
          selector: 'node',
          style: {
            shape: 'round-rectangle',
            width: 78, height: 78,
            'background-color': 'rgba(255,255,255,0.04)',
            'border-width': 1.5,
            'border-color': 'rgba(216,216,216,0.35)',
            'background-image': 'data(icon)',
            'background-fit': 'none',
            'background-width': '46px',
            'background-height': '46px',
            'background-position-y': '32%',
            label: 'data(label)',
            color: NODE_COLOUR,
            'font-size': '11px',
            'font-family': 'ui-monospace, monospace',
            'text-valign': 'bottom',
            'text-halign': 'center',
            'text-margin-y': -18,
          },
        },
        {
          selector: 'node[?unplaced]',
          // a native service with no host cannot be addressed yet — the resolver
          // says "unresolved", so the canvas says it too (gold = warning)
          style: { 'border-color': BM_GOLD, 'border-width': 2, 'border-style': 'dashed' },
        },
        {
          selector: 'node:selected',
          style: { 'border-color': BM_GREEN, 'border-width': 2.5,
                   'background-color': 'color-mix(in srgb, #1e9600 14%, transparent)' },
        },
        { selector: 'node.pending', style: { 'border-color': BM_GREEN, 'border-style': 'dotted', 'border-width': 3 } },
        {
          selector: 'edge',
          style: {
            width: 2,
            'line-color': EDGE_COLOUR,
            'target-arrow-color': EDGE_COLOUR,
            'target-arrow-shape': 'triangle',
            'arrow-scale': 0.9,
            'curve-style': 'bezier',
            label: 'data(label)',
            'font-size': '9px',
            'font-family': 'ui-monospace, monospace',
            color: EDGE_COLOUR,
            'text-background-color': '#0d0d0d',
            'text-background-opacity': 0.75,
            'text-background-padding': '2px',
          },
        },
      ],
      layout: { name: 'preset' },
      wheelSensitivity: 0.25,
      minZoom: 0.3,
      maxZoom: 2.5,
    });

    this.cy.on('tap', 'node', (ev) => this.onNodeTap(ev.target.id() as string));
    this.cy.on('tap', 'edge', (ev) => {
      const e = ev.target;
      this.selectEdge.emit({ from: e.source().id() as string, to: e.target().id() as string });
    });
    this.cy.on('tap', (ev) => {
      if (ev.target === this.cy) { this.select.emit(null); this.selectEdge.emit(null); this.cancelConnect(); }
    });
    this.cy.on('dbltap', 'node', (ev) => this.removeNode.emit(ev.target.id() as string));
    this.cy.on('dragfree', 'node', (ev) => {
      const p = ev.target.position();
      this.moved.emit({ name: ev.target.id() as string, x: p.x, y: p.y });
    });

    // E2E hook: Cytoscape draws to a <canvas>, so nodes are not DOM elements and a
    // test can't select them. Same escape hatch the runbook designer uses for
    // Blockly (`window.__rbWorkspace`) — it exposes the instance so a test can read
    // rendered positions and click the real coordinates.
    (window as unknown as { __bpCy?: cytoscape.Core }).__bpCy = this.cy;

    this.ready.set(true);
    this.sync(this.blueprint(), this.selected());
    setTimeout(() => { this.cy?.resize(); this.fit(); }, 60);
  }

  /** Rebuild elements from the document. Cytoscape is the VIEW; the blueprint is
   * the truth, so a full diff-free rebuild keeps the two from drifting. Positions
   * come from the document, so nothing jumps. */
  private sync(bp: Blueprint, sel: string | null): void {
    const cy = this.cy;
    if (!cy) return;
    const els: cytoscape.ElementDefinition[] = [];
    for (const s of bp.services) {
      els.push({
        data: {
          id: s.name,
          label: s.name,
          icon: iconFor(s.icon, NODE_COLOUR),
          // "unplaced" = a native service peers cannot address yet: neither a
          // planned address (IPAM/BIND) nor a host. Matches the resolver exactly.
          unplaced: s.kind === 'native' && !s.address && !s.host ? 1 : undefined,
        },
        position: { x: s.x, y: s.y },
      });
    }
    for (const s of bp.services) {
      for (const d of s.dependsOn) {
        const wired = Object.entries(s.bindings).filter(([, src]) => src === d).length;
        els.push({ data: { id: `${s.name}->${d}`, source: s.name, target: d,
                           label: wired ? `${wired} var` : 'depends_on' } });
      }
    }
    const zoom = cy.zoom(); const pan = cy.pan();
    cy.elements().remove();
    cy.add(els);
    cy.zoom(zoom); cy.pan(pan);
    cy.$(':selected').unselect();
    if (sel) cy.$id(sel).select();
    const p = this.pending();
    if (p) cy.$id(p).addClass('pending');
  }

  private onNodeTap(id: string): void {
    if (!this.connectMode()) { this.selectEdge.emit(null); this.select.emit(id); return; }
    const from = this.pending();
    if (!from) {
      this.pending.set(id);
      this.cy?.$id(id).addClass('pending');
      return;
    }
    this.cy?.$id(from).removeClass('pending');
    this.pending.set(null);
    this.connectMode.set(false);
    if (from !== id) this.connectPair.emit({ from, to: id });
  }

  onDragOver(ev: DragEvent): void {
    // Without preventDefault the browser refuses the drop entirely.
    ev.preventDefault();
    if (ev.dataTransfer) ev.dataTransfer.dropEffect = 'copy';
    this.dropHover.set(true);
  }

  /** Turn the drop point into MODEL coordinates: Cytoscape draws with its own pan
   * and zoom, so a raw client position would land in the wrong place as soon as the
   * canvas is panned or zoomed. */
  onDrop(ev: DragEvent): void {
    ev.preventDefault();
    this.dropHover.set(false);
    const icon = ev.dataTransfer?.getData('text/x-blueprint-icon');
    if (!icon || !this.cy) return;
    const box = this.hostRef().nativeElement.getBoundingClientRect();
    const pan = this.cy.pan();
    const zoom = this.cy.zoom();
    const x = (ev.clientX - box.left - pan.x) / zoom;
    const y = (ev.clientY - box.top - pan.y) / zoom;
    this.dropped.emit({ icon, x, y });
  }

  toggleConnect(): void {
    if (this.connectMode()) this.cancelConnect();
    else this.connectMode.set(true);
  }
  private cancelConnect(): void {
    const p = this.pending();
    if (p) this.cy?.$id(p).removeClass('pending');
    this.pending.set(null);
    this.connectMode.set(false);
  }

  /** Dependency-aware auto-arrange (dagre bottom-up: providers below consumers),
   * then write every position back so the layout is persisted. */
  autoLayout(): void {
    const cy = this.cy;
    if (!cy || cy.nodes().length === 0) return;
    const layout = cy.layout({ name: 'dagre', rankDir: 'TB', nodeSep: 60, rankSep: 90 } as cytoscape.LayoutOptions);
    layout.one('layoutstop', () => {
      cy.nodes().forEach((n) => {
        const p = n.position();
        this.moved.emit({ name: n.id() as string, x: p.x, y: p.y });
      });
      this.fit();
    });
    layout.run();
  }

  fit(): void { this.cy?.fit(undefined, 40); }

  ngOnDestroy(): void { this.cy?.destroy(); }
}
