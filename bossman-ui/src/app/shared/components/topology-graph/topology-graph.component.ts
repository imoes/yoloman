import { AfterViewInit, Component, ElementRef, OnDestroy, ViewChild, effect, input } from '@angular/core';
import cytoscape from 'cytoscape';
import dagre from 'cytoscape-dagre';
import { Agent } from '../../../core/models/agent.model';
import { HostEdge } from '../../../core/models/edge.model';
import { agentHealthStatus, serviceStateBadge } from '../../status.util';
import { BM_BLACK, BM_GOLD, BM_GREEN, BM_RED, BM_UNKNOWN } from '../../bm-colors';

cytoscape.use(dagre);

/** A structural proxy->satellite link derived from agents.parent_agent_id
 * — always drawn, unlike a real eBPF HostEdge which only exists once
 * traffic has actually been observed (see docs/plan.md's monitoring-
 * cockpit ergänzung Block F4). */
export interface ParentEdge {
  parent: string;
  child: string;
}

/** Renders the fleet's host-relationship graph (see docs/plan.md's
 * Bossman plan, section C.1 "Topologie" / C.3's shared component list):
 * node = agent (status-coloured), edge = a host_edges row (width scales
 * with event_count). v1 shows direct edges only, matching the REST API's
 * own depth=1 scope (see bossman/api/relationships.py). */
@Component({
  selector: 'app-topology-graph',
  standalone: true,
  template: `<div #container class="bm-topology"></div>`,
  styles: [
    `
      .bm-topology {
        width: 100%;
        height: 100%;
        min-height: 420px;
      }
    `,
  ],
})
export class TopologyGraphComponent implements AfterViewInit, OnDestroy {
  @ViewChild('container', { static: true }) containerRef!: ElementRef<HTMLDivElement>;

  agents = input.required<Agent[]>();
  edges = input.required<HostEdge[]>();
  parentEdges = input<ParentEdge[]>([]);
  hostStates = input<Map<string, string> | null>(null);

  private cy?: cytoscape.Core;

  constructor() {
    effect(() => {
      const agents = this.agents();
      const edges = this.edges();
      const parentEdges = this.parentEdges();
      const hostStates = this.hostStates();
      if (this.cy) this.render(agents, edges, parentEdges, hostStates);
    });
  }

  ngAfterViewInit(): void {
    this.cy = cytoscape({
      container: this.containerRef.nativeElement,
      style: [
        {
          selector: 'node',
          style: {
            label: 'data(label)',
            'font-size': 11,
            color: '#e6e6e6',
            'text-valign': 'bottom',
            'text-margin-y': 6,
            'background-color': BM_UNKNOWN,
            width: 28,
            height: 28,
            'border-width': 2,
            'border-color': BM_BLACK,
          },
        },
        { selector: 'node[status="ok"]', style: { 'background-color': BM_GREEN } },
        { selector: 'node[status="warn"]', style: { 'background-color': BM_GOLD } },
        { selector: 'node[status="crit"]', style: { 'background-color': BM_RED } },
        {
          selector: 'edge',
          style: {
            width: 'data(width)',
            'line-color': '#4a4a4a',
            'target-arrow-color': '#4a4a4a',
            'target-arrow-shape': 'triangle',
            'curve-style': 'bezier',
            label: 'data(label)',
            'font-size': 9,
            color: '#9a9a9a',
          },
        },
        // Proxy->satellite structural edges (see docs/plan.md's
        // monitoring-cockpit ergänzung Block F4): dashed and gold, so
        // they read as "this host relays that one" rather than
        // "observed traffic" (the solid grey eBPF edges above) — always
        // present, unlike a traffic edge which only exists once eBPF has
        // actually observed a connection.
        {
          selector: 'edge.parent-edge',
          style: {
            width: 2,
            'line-color': BM_GOLD,
            'target-arrow-color': BM_GOLD,
            'target-arrow-shape': 'triangle',
            'line-style': 'dashed',
            'curve-style': 'bezier',
            label: 'data(label)',
            'font-size': 9,
            color: BM_GOLD,
          },
        },
      ],
      layout: { name: 'dagre' } as cytoscape.LayoutOptions,
    });
    this.render(this.agents(), this.edges(), this.parentEdges(), this.hostStates());
  }

  ngOnDestroy(): void {
    this.cy?.destroy();
  }

  private render(agents: Agent[], edges: HostEdge[], parentEdges: ParentEdge[], hostStates: Map<string, string> | null): void {
    if (!this.cy) return;
    const known = new Set(agents.map((a) => a.id));

    const nodes = agents.map((a) => {
      const rollup = hostStates?.get(a.id);
      const status = rollup ? serviceStateBadge(rollup) : agentHealthStatus(a);
      return { data: { id: a.id, label: a.name, status } };
    });
    const edgeEls = edges
      .filter((e) => e.dst_agent_id && known.has(e.dst_agent_id))
      .map((e) => ({
        data: {
          id: `${e.src_agent_id}-${e.dst_agent_id}-${e.dst_port}`,
          source: e.src_agent_id,
          target: e.dst_agent_id as string,
          label: `${e.src_comm}:${e.dst_port}`,
          width: Math.min(1 + Math.log2(e.event_count + 1), 8),
        },
      }));
    const parentEdgeEls = parentEdges
      .filter((e) => known.has(e.parent) && known.has(e.child))
      .map((e) => ({
        classes: 'parent-edge',
        data: {
          id: `parent-${e.parent}-${e.child}`,
          source: e.parent,
          target: e.child,
          label: 'relays',
        },
      }));

    this.cy.elements().remove();
    this.cy.add([...nodes, ...edgeEls, ...parentEdgeEls]);
    this.cy.layout({ name: 'dagre' } as cytoscape.LayoutOptions).run();
  }
}
