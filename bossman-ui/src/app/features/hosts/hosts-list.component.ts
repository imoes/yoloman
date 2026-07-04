import { Component, OnInit, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { DatePipe } from '@angular/common';
import { MatCardModule } from '@angular/material/card';
import { AgentService } from '../../core/services/agent.service';
import { Agent } from '../../core/models/agent.model';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { agentHealthStatus } from '../../shared/status.util';

@Component({
  selector: 'app-hosts-list',
  standalone: true,
  imports: [RouterLink, DatePipe, MatCardModule, HostStatusBadgeComponent],
  template: `
    <div class="bm-page">
      <h1>Hosts</h1>
      <mat-card>
        <table class="bm-table">
          <thead>
            <tr>
              <th>Name</th>
              <th>Address</th>
              <th>Mode</th>
              <th>Status</th>
              <th>Last seen</th>
            </tr>
          </thead>
          <tbody>
            @for (agent of agents(); track agent.id) {
              <tr [routerLink]="['/hosts', agent.id]" class="bm-row-link">
                <td>{{ agent.name }}</td>
                <td>{{ agent.address || '—' }}</td>
                <td>{{ agent.mode }}</td>
                <td><app-status-badge [status]="statusOf(agent)" [label]="agent.enrollment_state" /></td>
                <td>{{ agent.last_seen_at ? (agent.last_seen_at | date: 'medium') : 'never' }}</td>
              </tr>
            } @empty {
              <tr>
                <td colspan="5" class="bm-empty">No hosts enrolled yet.</td>
              </tr>
            }
          </tbody>
        </table>
      </mat-card>
    </div>
  `,
  styles: [
    `
      .bm-page {
        padding: 24px;
        max-width: 1100px;
        margin: 0 auto;
      }
      .bm-table {
        width: 100%;
        border-collapse: collapse;
      }
      .bm-table th {
        text-align: left;
        font-size: 12px;
        opacity: 0.7;
        padding: 10px 12px;
      }
      .bm-table td {
        padding: 10px 12px;
        border-top: 1px solid var(--mat-sys-outline-variant);
      }
      .bm-row-link {
        cursor: pointer;
      }
      .bm-row-link:hover {
        background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent);
      }
      .bm-empty {
        opacity: 0.6;
        text-align: center;
      }
    `,
  ],
})
export class HostsListComponent implements OnInit {
  private agentService = inject(AgentService);
  agents = signal<Agent[]>([]);

  ngOnInit(): void {
    this.agentService.list().subscribe((agents) => this.agents.set(agents));
  }

  statusOf(agent: Agent) {
    return agentHealthStatus(agent);
  }
}
