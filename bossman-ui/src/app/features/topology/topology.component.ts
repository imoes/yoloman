import { Component, OnInit, inject, signal } from '@angular/core';
import { MatCardModule } from '@angular/material/card';
import { AgentService } from '../../core/services/agent.service';
import { RelationshipService } from '../../core/services/relationship.service';
import { Agent } from '../../core/models/agent.model';
import { HostEdge } from '../../core/models/edge.model';
import { TopologyGraphComponent } from '../../shared/components/topology-graph/topology-graph.component';

@Component({
  selector: 'app-topology',
  standalone: true,
  imports: [MatCardModule, TopologyGraphComponent],
  template: `
    <div class="bm-page">
      <h1>Topology</h1>
      <mat-card class="bm-topology-card">
        @if (agents().length) {
          <app-topology-graph [agents]="agents()" [edges]="edges()" />
        } @else {
          <p class="bm-empty">No hosts enrolled yet.</p>
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

  agents = signal<Agent[]>([]);
  edges = signal<HostEdge[]>([]);

  ngOnInit(): void {
    this.agentService.list().subscribe((agents) => this.agents.set(agents));
    this.relationshipService.list().subscribe((edges) => this.edges.set(edges));
  }
}
