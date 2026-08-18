import { Component, effect, inject, input, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { forkJoin } from 'rxjs';
import { CompiledHostState } from '../../../core/models/orchestration.model';
import { AgentService } from '../../../core/services/agent.service';
import { OrchestrationService } from '../../../core/services/orchestration.service';
import {
  ConfigDesiredResource,
  DesiredStateReportComponent,
} from '../../../shared/components/desired-state-report/desired-state-report.component';

/** The host's full compiled desired state — the GPO-merged result of the global, OU, group and host
 * layers, rendered as a gpresult-style report.
 *
 * Third slice out of host-detail.component.ts. Small, and it deletes a piece of machinery outright
 * rather than moving it: the parent had an onConfigSubTab() handler whose ONLY job was to lazy-load
 * this document the first time the sub-tab was opened. A component inside <ng-template matTabContent>
 * is not constructed until that tab is opened, so the load happens on first open by construction
 * alone — and the handler, along with the (selectedTabChange) binding it hung on, has nothing left
 * to do. (The load itself sits in an effect, not the constructor; see there for why.)
 *
 * Two signals fetched together on purpose: the compiled state and the per-file config resources are
 * one answer to "what should this host look like", and showing half of it while the other half is
 * still in flight would invite reading a partial document as the whole.
 */
@Component({
  selector: 'app-host-desired-state',
  standalone: true,
  imports: [MatButtonModule, MatIconModule, DesiredStateReportComponent],
  template: `
    <div class="bm-ds-head">
      <span class="bm-dim">The full compiled desired_state for this host — the GPO-merged result of the global, OU, group and host layers.</span>
      <button mat-stroked-button (click)="load()" [disabled]="loading()"><mat-icon>refresh</mat-icon> Reload</button>
    </div>
    @if (loading()) {
      <p class="bm-empty">Compiling the desired state…</p>
    } @else if (error(); as e) {
      <p class="bm-empty">{{ e }}</p>
    } @else if (state(); as ds) {
      <app-desired-state-report [state]="ds" [config]="config()" />
    }
  `,
  styles: [`
    .bm-ds-head { display: flex; align-items: baseline; justify-content: space-between; gap: 16px; margin-bottom: 10px; }
    .bm-dim { opacity: 0.62; font-size: 12.5px; max-width: 90ch; }
    .bm-empty { opacity: 0.6; font-size: 13px; }
  `],
})
export class HostDesiredStateComponent {
  private agentService = inject(AgentService);
  private orchestration = inject(OrchestrationService);

  agentId = input.required<string>();

  state = signal<CompiledHostState | null>(null);
  config = signal<ConfigDesiredResource[] | null>(null);
  loading = signal(false);
  error = signal<string | null>(null);

  constructor() {
    // NOT in the constructor: a required input is not bound yet there, and reading agentId() threw
    // NG0950 on the first open. Caught in the browser, not by the compiler — which is the whole
    // reason each slice gets clicked through rather than only built.
    //
    // An effect runs after inputs are set, and reruns if the component is ever pointed at another
    // host. The lazy part is still free: matTabContent does not construct this component until its
    // tab is selected, which is why the parent's lazy-load handler could be DELETED rather than
    // moved — the component boundary already expresses "not until someone looks".
    effect(() => { this.agentId(); this.load(); });
  }

  load(): void {
    this.loading.set(true);
    this.error.set(null);
    forkJoin({
      state: this.orchestration.desiredState(this.agentId()),
      config: this.agentService.configDesired(this.agentId()),
    }).subscribe({
      next: ({ state, config }) => {
        this.state.set(state);
        this.config.set(config.resources);
        this.loading.set(false);
      },
      error: (e: { error?: { detail?: string } }) => {
        this.error.set(e?.error?.detail ?? 'failed to load desired state');
        this.loading.set(false);
      },
    });
  }
}
