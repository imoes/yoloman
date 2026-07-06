import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { MatCardModule } from '@angular/material/card';
import { AgentService } from '../../core/services/agent.service';
import { RelationshipService } from '../../core/services/relationship.service';
import { MonitoringService } from '../../core/services/monitoring.service';
import { Agent } from '../../core/models/agent.model';
import { HostEdge } from '../../core/models/edge.model';
import { TopologyGraphComponent, ParentEdge } from '../../shared/components/topology-graph/topology-graph.component';

@Component({
  selector: 'app-topology',
  standalone: true,
  imports: [RouterLink, MatCardModule, TopologyGraphComponent],
  template: `
    <div class="bm-page">
      <h1>Topology</h1>
      <mat-card class="bm-topology-card">
        @if (agents().length) {
          <app-topology-graph [agents]="agents()" [edges]="edges()" [parentEdges]="parentEdges()" [hostStates]="hostStates()" />
        } @else {
          <p class="bm-empty">No hosts enrolled yet. Go to <a routerLink="/settings">Settings</a> for the enrollment command.</p>
        }
      </mat-card>
    </div>
  `,
  styles: [
    `
      .bm-page {
        padding: 24px;
        max-width: 1200px;
        margin: 0 auto;
        height: calc(100vh - 48px);
        display: flex;
        flex-direction: column;
      }
      .bm-topology-card {
        flex: 1;
        min-height: 0;
        display: flex;
      }
      .bm-empty {
        opacity: 0.6;
        margin: 24px;
      }
    `,
  ],
})
export class TopologyComponent implements OnInit {
  private agentService = inject(AgentService);
  private relationshipService = inject(RelationshipService);
  private monitoringService = inject(MonitoringService);

  agents = signal<Agent[]>([]);
  edges = signal<HostEdge[]>([]);
  hostStates = signal<Map<string, string>>(new Map());

  /** Proxy->satellite structural edges derived from agents.parent_agent_id
   * (see docs/plan.md's monitoring-cockpit ergänzung Block F4) — drawn
   * unconditionally, unlike the real eBPF host_edges below, which are
   * empty until traffic is actually observed. This is the fix for a
   * satellite behind a proxy being an invisible, disconnected dot. */
  parentEdges = computed<ParentEdge[]>(() =>
    this.agents()
      .filter((a): a is Agent & { parent_agent_id: string } => !!a.parent_agent_id)
      .map((a) => ({ parent: a.parent_agent_id, child: a.id })),
  );

  ngOnInit(): void {
    this.agentService.list().subscribe((agents) => this.agents.set(agents));
    this.relationshipService.list().subscribe((edges) => this.edges.set(edges));
    this.monitoringService.fleetHosts().subscribe((hosts) => {
      const m = new Map<string, string>();
      for (const h of hosts) m.set(h.id, h.state_rollup);
      this.hostStates.set(m);
    });
  }
}
