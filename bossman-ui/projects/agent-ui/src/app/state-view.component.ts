import { Component, inject, signal, OnInit, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { AgentApi, ObservedState, ObservedResource, StateGeneration, StateApplyResult } from './agent-api.service';

/**
 * Server-as-a-document view: the whole host's config as JSON (observed), its
 * generation history, and a dry-run → confirm rollback to any earlier
 * generation. The browser face of plan/apply/rollback.
 */
@Component({
  selector: 'app-state-view',
  standalone: true,
  imports: [CommonModule],
  template: `
    <div class="sv">
      <div class="sv-head">
        <h2>State</h2>
        <button (click)="refresh()" [disabled]="loading()">↻ Refresh</button>
        <span class="sv-err" *ngIf="error()">{{ error() }}</span>
      </div>

      <section>
        <h3>Observed config <span class="dim" *ngIf="observed() as o">({{ o.config.length }} files)</span></h3>
        <table class="grid" *ngIf="observed() as o">
          <thead><tr><th>Path</th><th>Format</th><th>Content</th></tr></thead>
          <tbody>
            <tr *ngFor="let r of o.config">
              <td class="mono">{{ r.path }}</td>
              <td>{{ r.format || 'raw' }}</td>
              <td class="mono small">
                <span *ngIf="r.values">{{ summarize(r) }}</span>
                <span *ngIf="!r.values && r.sha256" class="dim">sha256 {{ r.sha256.slice(0, 12) }} · {{ r.size }} B</span>
                <span *ngIf="r.error" class="sv-err">{{ r.error }}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <section>
        <h3>Generations</h3>
        <table class="grid" *ngIf="generations().length; else noGen">
          <thead><tr><th class="n">#</th><th>Applied</th><th>Hash</th><th class="n">Resources</th><th></th></tr></thead>
          <tbody>
            <tr *ngFor="let g of generations()">
              <td class="n">{{ g.number }}</td>
              <td>{{ g.applied_at | date: 'short' }}</td>
              <td class="mono small">{{ g.hash }}</td>
              <td class="n">{{ g.resources }}</td>
              <td><button (click)="planRollback(g.number)" [disabled]="busy()">Rollback…</button></td>
            </tr>
          </tbody>
        </table>
        <ng-template #noGen><p class="dim">No generations recorded yet (apply a state to create one).</p></ng-template>
      </section>

      <div class="sv-modal" *ngIf="pending() as p">
        <div class="sv-card">
          <h3>Roll back to generation {{ p.target }}?</h3>
          <p class="dim">This re-applies that generation forward. Changes:</p>
          <table class="grid">
            <tr *ngFor="let c of p.result.plan.changes" [class.noop]="c.action === 'noop'">
              <td class="mono">{{ c.path }}</td><td>{{ c.action }}</td>
              <td class="mono small">{{ changedKeys(c) }}</td>
            </tr>
          </table>
          <div class="sv-actions">
            <button (click)="pending.set(null)">Cancel</button>
            <button class="apply" (click)="confirmRollback(p.target)" [disabled]="busy()">Apply rollback</button>
          </div>
        </div>
      </div>
    </div>
  `,
  styles: [`
    .sv { padding: 12px; }
    .sv-head { display: flex; gap: 10px; align-items: center; }
    .sv-err { color: #f44034; }
    section { margin-top: 16px; }
    .grid { width: 100%; border-collapse: collapse; font-size: 13px; }
    .grid th, .grid td { text-align: left; padding: 3px 8px; border-bottom: 1px solid #eee; vertical-align: top; }
    .grid .n { text-align: right; }
    .grid tr.noop { opacity: 0.5; }
    .mono { font-family: monospace; }
    .small { font-size: 12px; }
    .dim { opacity: 0.6; }
    button { padding: 3px 10px; cursor: pointer; }
    .sv-modal { position: fixed; inset: 0; background: rgba(0,0,0,0.4); display: flex; align-items: center; justify-content: center; }
    .sv-card { background: #fff; padding: 18px; border-radius: 8px; max-width: 640px; max-height: 80vh; overflow: auto; }
    .sv-actions { display: flex; gap: 8px; justify-content: flex-end; margin-top: 12px; }
    .sv-actions .apply { font-weight: 700; background: #2e7d32; color: #fff; border: none; border-radius: 4px; }
  `],
})
export class StateViewComponent implements OnInit {
  private api = inject(AgentApi);
  observed = signal<ObservedState | null>(null);
  generations = signal<StateGeneration[]>([]);
  loading = signal(false);
  busy = signal(false);
  error = signal<string | null>(null);
  pending = signal<{ target: number; result: StateApplyResult } | null>(null);

  ngOnInit(): void { this.refresh(); }

  refresh(): void {
    this.loading.set(true);
    this.error.set(null);
    this.api.stateObserved().subscribe({
      next: (o) => { this.observed.set(o); this.loading.set(false); },
      error: (e) => { this.error.set(this.msg(e)); this.loading.set(false); },
    });
    this.api.stateGenerations().subscribe({
      next: (r) => this.generations.set(r.generations || []),
      error: () => {},
    });
  }

  summarize(r: ObservedResource): string {
    const keys = Object.keys(r.values || {});
    return keys.slice(0, 6).join(', ') + (keys.length > 6 ? ` … (+${keys.length - 6})` : '');
  }

  changedKeys(c: { changed?: Record<string, [unknown, unknown]> }): string {
    const ch = c.changed || {};
    return Object.entries(ch).map(([k, v]) => `${k}: ${v[0] ?? '∅'}→${v[1] ?? '∅'}`).slice(0, 5).join('; ');
  }

  planRollback(gen: number): void {
    this.busy.set(true);
    this.api.stateRollback(gen, true).subscribe({
      next: (res) => { this.pending.set({ target: gen, result: res }); this.busy.set(false); },
      error: (e) => { this.error.set(this.msg(e)); this.busy.set(false); },
    });
  }

  confirmRollback(gen: number): void {
    this.busy.set(true);
    this.api.stateRollback(gen, false).subscribe({
      next: () => { this.busy.set(false); this.pending.set(null); this.refresh(); },
      error: (e) => { this.error.set(this.msg(e)); this.busy.set(false); },
    });
  }

  private msg(e: any): string { return e?.error?.error || e?.message || 'request failed'; }
}
