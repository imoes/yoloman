import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { DatePipe } from '@angular/common';
import { MatCardModule } from '@angular/material/card';
import { RunService } from '../../core/services/run.service';
import { DeploymentService } from '../../core/services/deployment.service';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { runStatusBadge } from '../../shared/status.util';

/** Block F6 — unified Runs: plan runs, runbook runs, and deployments in one
 * timeline with a type filter (was three fragmented places). A plan run links
 * to its detail; runbook/deploy rows show inline (their detail views live
 * elsewhere). */
interface UnifiedRun {
  id: string;
  type: 'plan' | 'runbook' | 'deploy';
  name: string;
  status: string;
  dryRun: boolean;
  by: string;
  when: string;
  link: string[] | null;
}

@Component({
  selector: 'app-runs-list',
  standalone: true,
  imports: [RouterLink, DatePipe, MatCardModule, HostStatusBadgeComponent],
  template: `
    <div class="bm-page">
      <h1>Runs</h1>
      <div class="bm-run-filter">
        @for (t of types; track t.key) {
          <button class="bm-chip" [class.bm-chip-on]="typeFilter() === t.key" (click)="typeFilter.set(t.key)">{{ t.label }}</button>
        }
      </div>
      <mat-card>
        <table class="bm-table">
          <thead>
            <tr><th>Type</th><th>Name</th><th>Status</th><th>Dry run</th><th>By</th><th>When</th></tr>
          </thead>
          <tbody>
            @for (run of filtered(); track run.type + run.id) {
              @if (run.link) {
                <tr [routerLink]="run.link" class="bm-row-link">
                  <td><span class="bm-type bm-type-{{ run.type }}">{{ run.type }}</span></td>
                  <td>{{ run.name }}</td>
                  <td><app-status-badge [status]="badge(run.status)" [label]="run.status" /></td>
                  <td>{{ run.dryRun ? 'yes' : 'no' }}</td>
                  <td>{{ run.by || '—' }}</td>
                  <td>{{ run.when | date: 'medium' }}</td>
                </tr>
              } @else {
                <tr>
                  <td><span class="bm-type bm-type-{{ run.type }}">{{ run.type }}</span></td>
                  <td>{{ run.name }}</td>
                  <td><app-status-badge [status]="badge(run.status)" [label]="run.status" /></td>
                  <td>{{ run.dryRun ? 'yes' : 'no' }}</td>
                  <td>{{ run.by || '—' }}</td>
                  <td>{{ run.when | date: 'medium' }}</td>
                </tr>
              }
            } @empty {
              <tr><td colspan="6" class="bm-empty">No runs yet.</td></tr>
            }
          </tbody>
        </table>
      </mat-card>
    </div>
  `,
  styles: [
    `
      .bm-page { padding: 24px; max-width: 1100px; margin: 0 auto; }
      .bm-run-filter { display: flex; gap: 8px; margin: 12px 0; }
      .bm-chip { padding: 5px 14px; border-radius: 16px; border: 1px solid var(--mat-sys-outline-variant); background: transparent; color: inherit; cursor: pointer; font-size: 13px; }
      .bm-chip-on { background: var(--mat-sys-primary); color: var(--mat-sys-on-primary); border-color: transparent; }
      .bm-table { width: 100%; border-collapse: collapse; }
      .bm-table th { text-align: left; font-size: 12px; opacity: 0.7; padding: 10px 12px; }
      .bm-table td { padding: 10px 12px; border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-row-link { cursor: pointer; }
      .bm-row-link:hover { background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent); }
      .bm-empty { opacity: 0.6; text-align: center; }
      .bm-type { font-size: 11px; text-transform: uppercase; padding: 2px 7px; border-radius: 4px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
      .bm-type-plan { background: color-mix(in srgb, #1565c0 22%, transparent); }
      .bm-type-runbook { background: color-mix(in srgb, #6a1b9a 22%, transparent); }
      .bm-type-deploy { background: color-mix(in srgb, #2e7d32 22%, transparent); }
    `,
  ],
})
export class RunsListComponent implements OnInit {
  private runService = inject(RunService);
  private deploymentService = inject(DeploymentService);

  readonly types = [
    { key: 'all', label: 'All' },
    { key: 'plan', label: 'Plans' },
    { key: 'runbook', label: 'Runbooks' },
    { key: 'deploy', label: 'Deployments' },
  ] as const;

  typeFilter = signal<string>('all');
  private all = signal<UnifiedRun[]>([]);
  filtered = computed(() => {
    const t = this.typeFilter();
    const rows = t === 'all' ? this.all() : this.all().filter((r) => r.type === t);
    return [...rows].sort((a, b) => (a.when < b.when ? 1 : -1));
  });

  ngOnInit(): void {
    this.runService.list({ limit: 100 }).subscribe((runs) =>
      this.merge(runs.map((r) => ({
        id: r.id, type: 'plan' as const, name: r.plan_name, status: r.status, dryRun: r.dry_run,
        by: r.requested_by || '', when: r.started_at, link: ['/runs', r.id],
      }))),
    );
    this.runService.runbookRuns(100).subscribe((res) =>
      this.merge((res.runs ?? []).map((r) => ({
        id: r.id, type: 'runbook' as const, name: r.runbook_name, status: r.status, dryRun: r.dry_run,
        by: r.requested_by || '', when: r.created_at, link: null,
      }))),
    );
    this.deploymentService.list(50).subscribe((res) =>
      this.merge((res.deployments ?? []).map((d) => ({
        id: d.id, type: 'deploy' as const, name: d.target_ref || d.kind, status: d.status, dryRun: d.dry_run,
        by: '', when: (d as { created_at?: string }).created_at || '', link: null,
      }))),
    );
  }

  private merge(rows: UnifiedRun[]): void {
    this.all.update((cur) => [...cur, ...rows]);
  }

  badge(status: string) {
    return runStatusBadge(status);
  }
}
