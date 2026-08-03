import { Component, computed, effect, inject, input, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { DeploymentRun, DeploymentService } from '../../core/services/deployment.service';

/**
 * The deployment EDGE, in both directions (docs/ui-workspaces.md slice 4).
 *
 * Give it an `agentId` and it answers "what is deployed on this host"; give it a `targetRef` and it answers
 * "where is this artefact deployed". Same component, same endpoint, one filter — because a Deployment is
 * the recorded apply() binding an artefact to a target, so both questions are one query with a different
 * where-clause. These are the links the UI was missing between the Library and the Fleet.
 */
@Component({
  selector: 'app-deployment-edges',
  standalone: true,
  imports: [RouterLink],
  template: `
    <div class="bm-de">
      @if (loading()) {
        <p class="bm-de-dim">loading deployments…</p>
      } @else if (rows().length) {
        <table class="bm-de-t">
          <thead>
            <tr>
              <th>{{ agentId() ? 'Artefact' : 'Host' }}</th>
              <th>Kind</th><th>Status</th><th>Hosts</th><th>When</th><th></th>
            </tr>
          </thead>
          <tbody>
            @for (d of rows(); track d.id) {
              <tr>
                <td class="bm-de-mono">{{ agentId() ? d.target_ref : hostsOf(d) }}</td>
                <td class="bm-de-dim">{{ d.kind }}</td>
                <td [class.bm-de-bad]="d.status === 'failed'" [class.bm-de-part]="d.status === 'partial'">
                  {{ d.status }}{{ d.dry_run ? ' (dry-run)' : '' }}
                </td>
                <td class="bm-de-dim">{{ d.ok_hosts }}/{{ d.total_hosts }} ok</td>
                <td class="bm-de-dim">{{ d.created_at }}</td>
                <td><a [routerLink]="['/runs']" [queryParams]="{ deployment: d.id }">open</a></td>
              </tr>
            }
          </tbody>
        </table>
      } @else {
        <p class="bm-de-dim">
          @if (agentId()) { Nothing has been deployed to this host yet. }
          @else { This artefact has not been deployed anywhere yet. }
        </p>
      }
    </div>
  `,
  styles: [`
    .bm-de-t { width: 100%; border-collapse: collapse; font-size: 12.5px; }
    .bm-de-t th { text-align: left; font-size: 11px; opacity: .6; padding: 4px 6px; font-weight: 500; }
    .bm-de-t td { padding: 4px 6px; border-top: 1px solid var(--mat-sys-outline-variant); }
    .bm-de-mono { font-family: ui-monospace, monospace; word-break: break-all; }
    .bm-de-dim { opacity: .65; }
    .bm-de-bad { color: var(--mat-sys-error, #c62828); }
    .bm-de-part { color: var(--bm-gold, #b8860b); }
  `],
})
export class DeploymentEdgesComponent {
  private svc = inject(DeploymentService);

  /** Set exactly one: the host whose deployments to list, or the artefact whose deployments to list. */
  agentId = input<string>('');
  targetRef = input<string>('');
  limit = input<number>(25);

  rows = signal<DeploymentRun[]>([]);
  loading = signal(false);

  constructor() {
    effect(() => {
      const agentId = this.agentId();
      const targetRef = this.targetRef();
      if (!agentId && !targetRef) { this.rows.set([]); return; }
      this.loading.set(true);
      this.svc.list(this.limit(), { agentId: agentId || undefined, targetRef: targetRef || undefined })
        .subscribe({
          next: (r) => { this.rows.set(r.deployments ?? []); this.loading.set(false); },
          error: () => { this.rows.set([]); this.loading.set(false); },
        });
    });
  }

  /**
   * For the artefact direction: which hosts this deployment touched. The list endpoint sends `host_names`
   * (the brief form omits the full per-host `results`), so prefer that and fall back to the count.
   */
  hostsOf(d: DeploymentRun): string {
    const names = (d.host_names?.length ? d.host_names : (d.results ?? []).map((r) => r.agent_name))
      .filter(Boolean) as string[];
    if (!names.length) return `${d.total_hosts} host(s)`;
    return names.length <= 3 ? names.join(', ') : `${names.slice(0, 3).join(', ')} +${names.length - 3}`;
  }
}
