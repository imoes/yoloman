import { AfterViewInit, Component, ElementRef, OnDestroy, inject, input } from '@angular/core';
import cytoscape from 'cytoscape';
import dagre from 'cytoscape-dagre';

cytoscape.use(dagre);

export interface PlanGraphData {
  nodes: { id: string; label?: string }[];
  edges: { from: string; to: string; label?: string }[];
}

/** Block K6 — renders a plan/workflow as a left-to-right DAG (cytoscape +
 * dagre), from a ```bm-widget``` block of widget_type "plan_graph". Lets the
 * AI visualize plans/workflows in planning mode. */
@Component({
  selector: 'app-chat-plan-graph',
  standalone: true,
  template: `<div class="bm-plan-graph" #host></div>`,
  styles: [`.bm-plan-graph { width: 100%; height: 220px; }`],
})
export class ChatPlanGraphComponent implements AfterViewInit, OnDestroy {
  private hostEl = inject(ElementRef<HTMLElement>);
  data = input.required<PlanGraphData>();
  private cy: cytoscape.Core | null = null;

  ngAfterViewInit(): void {
    const container = this.hostEl.nativeElement.querySelector('.bm-plan-graph') as HTMLElement;
    const d = this.data();
    const nodes = (d.nodes ?? []).map((n) => ({ data: { id: n.id, label: n.label ?? n.id } }));
    const edges = (d.edges ?? [])
      .filter((e) => e.from && e.to)
      .map((e, i) => ({ data: { id: `e${i}`, source: e.from, target: e.to, label: e.label ?? '' } }));
    this.cy = cytoscape({
      container,
      elements: [...nodes, ...edges],
      style: [
        {
          selector: 'node',
          style: {
            'background-color': '#1e9600',
            label: 'data(label)',
            color: '#e6e6e6',
            'font-size': '10px',
            'text-valign': 'center',
            'text-halign': 'center',
            'text-wrap': 'wrap',
            'text-max-width': '90px',
            width: 'label',
            height: 'label',
            padding: '8px',
            shape: 'round-rectangle',
          },
        },
        {
          selector: 'edge',
          style: {
            width: 2,
            'line-color': '#8a8a8a',
            'target-arrow-color': '#8a8a8a',
            'target-arrow-shape': 'triangle',
            'curve-style': 'bezier',
            label: 'data(label)',
            'font-size': '8px',
            color: '#8a8a8a',
          },
        },
      ],
      layout: { name: 'dagre', rankDir: 'LR' } as cytoscape.LayoutOptions,
    });
  }

  ngOnDestroy(): void {
    this.cy?.destroy();
  }
}
