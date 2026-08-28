import { Component, effect, inject, input, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { OrchestrationService } from '../../../core/services/orchestration.service';

interface AppliedPlan {
  name: string;
  version: number | null;
  type: string;
  source: string;
}

/** Policies snap-in — which plans/policies actually reach THIS host, and from where.
 *
 * MOVED here from the Configuration tab's pseudo-categories, for the same reason as Variables: that
 * tab is a Miller list of config FILES, and a policy is not one. It sat between "Security & access"
 * and "Time synchronization" as though it were a file, which made the list's own category meaning
 * untrue.
 *
 * It is a READ of the compiled desired state, deliberately: the host is where you ask "what applies
 * to me and why", and OU / Policy is where you change it. Offering an edit here would put the rule
 * (which spans hosts) behind a door labelled with one host — the intension/extension confusion this
 * design keeps apart. Hence the `source` column and the link out, rather than buttons.
 */
@Component({
  selector: 'app-host-policies',
  standalone: true,
  imports: [RouterLink, MatButtonModule, MatIconModule],
  template: `
    <div class="bm-mgmt-section">
      <div class="bm-pol-head">
        <div>
          <h3>Policies</h3>
          <p class="bm-dim">
            The plans and policies that apply to this host, merged GPO-style from global, OU, group
            and host layers. <b>Source</b> says which layer contributed it — that is the answer to
            “why is this here?”, and it is why the column is not decoration.
          </p>
        </div>
        <button mat-stroked-button (click)="load()" [disabled]="busy()">
          <mat-icon>refresh</mat-icon> Reload
        </button>
      </div>

      @if (busy()) {
        <p class="bm-dim">Loading…</p>
      } @else if (err()) {
        <p class="bm-pol-err">{{ err() }}</p>
      } @else if (plans().length) {
        <table class="bm-pol-tbl">
          <thead><tr><th>Policy</th><th>Type</th><th>Version</th><th>Source</th></tr></thead>
          <tbody>
            @for (p of plans(); track p.name) {
              <tr>
                <td>{{ p.name }}</td>
                <td class="bm-dim">{{ p.type }}</td>
                <td>{{ p.version ?? '—' }}</td>
                <td><span class="bm-tag">{{ p.source }}</span></td>
              </tr>
            }
          </tbody>
        </table>
      } @else {
        <p class="bm-dim">
          No plans or policies apply to this host. Link one in
          <a routerLink="/ou">OU&nbsp;/&nbsp;Policy</a> — a policy is written once for a scope and
          reaches every host the scope covers, so it is authored there rather than per host.
        </p>
      }
    </div>
  `,
  styles: [`
    .bm-pol-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; margin-bottom: 12px; }
    .bm-pol-head h3 { margin: 0; }
    .bm-dim { opacity: 0.62; margin: 2px 0 0; font-size: 13px; max-width: 82ch; }
    .bm-pol-err { font-size: 13px; color: var(--bm-red, #d0021b); }
    .bm-pol-tbl { width: 100%; border-collapse: collapse; font-size: 13px; }
    .bm-pol-tbl th { text-align: left; font-size: 12px; opacity: 0.6; padding: 6px 10px; }
    .bm-pol-tbl td { padding: 8px 10px; border-top: 1px solid var(--mat-sys-outline-variant); }
    .bm-tag { font-size: 11px; padding: 1px 8px; border-radius: 10px;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
  `],
})
export class HostPoliciesComponent {
  private orchestration = inject(OrchestrationService);
  agentId = input.required<string>();

  plans = signal<AppliedPlan[]>([]);
  busy = signal(false);
  err = signal<string | null>(null);

  constructor() {
    // Reload when the snap-in is pointed at a different host, not only on construction — the Miller
    // list keeps the component alive while the selection moves.
    effect(() => { this.agentId(); this.load(); });
  }

  load(): void {
    this.busy.set(true);
    this.err.set(null);
    this.orchestration.desiredState(this.agentId()).subscribe({
      next: (d) => {
        // `source` lives in explain.assignments, not next to the plan: the compiled state says WHAT
        // applies, the explain block says WHY. Joining them here is what turns a list into an
        // answer — a plan without its origin cannot be acted on.
        const explain = (d.explain ?? {}) as { assignments?: { plan: string; source: string }[] };
        const srcByPlan = new Map((explain.assignments ?? []).map((a) => [a.plan, a.source] as const));
        this.plans.set((d.state.orchestration?.plans ?? []).map((p) => ({
          name: p.name, version: p.version, type: p.type, source: srcByPlan.get(p.name) ?? 'ou',
        })));
        this.busy.set(false);
      },
      error: (e) => {
        this.busy.set(false);
        this.err.set(e?.error?.detail ?? 'could not read the compiled desired state for this host');
      },
    });
  }
}
