import { AfterViewInit, Component, ElementRef, OnDestroy, ViewChild, effect, input } from '@angular/core';
import cytoscape from 'cytoscape';
import dagre from 'cytoscape-dagre';
import { Agent } from '../../../core/models/agent.model';
import { HostEdge } from '../../../core/models/edge.model';
import { agentHealthStatus } from '../../status.util';

cytoscape.use(dagre);

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

  private cy?: cytoscape.Core;

  constructor() {
    effect(() => {
      const agents = this.agents();
      const edges = this.edges();
      if (this.cy) this.render(agents, edges);
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
            'background-color': '#8a8a8a',
            width: 28,
            height: 28,
            'border-width': 2,
            'border-color': '#0d0d0d',
          },
        },
        { selector: 'node[status="ok"]', style: { 'background-color': '#1e9600' } },
        { selector: 'node[status="warn"]', style: { 'background-color': '#ffc800' } },
        { selector: 'node[status="crit"]', style: { 'background-color': '#d0021b' } },
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
      ],
      layout: { name: 'dagre' } as cytoscape.LayoutOptions,
    });
    this.render(this.agents(), this.edges());
  }

  ngOnDestroy(): void {
    this.cy?.destroy();
  }

  private render(agents: Agent[], edges: HostEdge[]): void {
    if (!this.cy) return;
    const known = new Set(agents.map((a) => a.id));

    const nodes = agents.map((a) => ({
      data: { id: a.id, label: a.name, status: agentHealthStatus(a) },
    }));
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

    this.cy.elements().remove();
    this.cy.add([...nodes, ...edgeEls]);
    this.cy.layout({ name: 'dagre' } as cytoscape.LayoutOptions).run();
  }
}
