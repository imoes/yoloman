import { Component, effect, inject, input, output, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { RouterLink } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { environment } from '../../../environments/environment';

interface HistoryItem {
  id: string; target: { kind: string; name: string }; status: string; summary: string;
  leading_rule: string | null; leading_certainty: 'Proven' | 'Likely' | 'Unknown' | null;
  contract_status: 'ok' | 'violation'; collected_at: string; agent_version: string | null;
}

/**
 * A host's past diagnoses, newest first (UX concept #3). Reads GET /agents/{id}/diagnoses (the stored rows, without
 * the documents) so an operator can see whether a problem is new or recurring before asking for a fresh one. Each row
 * links to the diagnosis permalink (/diagnoses/:id). Read-only: nothing here asks the host or changes anything.
 */
@Component({
  selector: 'app-diagnosis-history',
  standalone: true,
  imports: [RouterLink, MatButtonModule, MatIconModule],
  template: `
    <section class="dh">
      <header class="dh-head">
        <h3><mat-icon>history</mat-icon> Past diagnoses on {{ host() }}</h3>
        <span class="dh-sp"></span>
        <a mat-stroked-button routerLink="/diagnoses" title="Every host's diagnoses"><mat-icon>troubleshoot</mat-icon> Fleet-wide</a>
        <button mat-stroked-button (click)="load()" [disabled]="busy()"><mat-icon>refresh</mat-icon> Refresh</button>
        <button mat-icon-button aria-label="Close" (click)="closed.emit()"><mat-icon>close</mat-icon></button>
      </header>

      @if (busy()) { <p class="dh-dim">Reading the stored diagnoses…</p> }
      @if (error()) { <p class="dh-err">{{ error() }}</p> }

      @if (items(); as rows) {
        @for (r of rows; track r.id) {
          <a class="dh-row" [routerLink]="['/diagnoses', r.id]" [attr.data-id]="r.id">
            <code class="dh-at">{{ r.collected_at }}</code>
            <span class="dh-target">{{ r.target.name || r.target.kind }}</span>
            @if (r.leading_certainty) {
              <span class="dh-cert dh-cert--{{ r.leading_certainty.toLowerCase() }}">{{ r.leading_certainty }}</span>
            }
            <span class="dh-rule dh-dim">{{ r.leading_rule || r.status }}</span>
            @if (r.contract_status === 'violation') { <span class="dh-viol" title="Did not hold the contract">violation</span> }
            <span class="dh-summary dh-dim">{{ r.summary }}</span>
            <mat-icon class="dh-go">chevron_right</mat-icon>
          </a>
        } @empty {
          <p class="dh-dim">No diagnosis has been saved for this host yet. Run "Why is it not running?" on a service.</p>
        }
      }
    </section>
  `,
  styles: [`
    .dh { border: 1px solid var(--bm-border, #ccc); border-radius: 8px; padding: 10px 14px; margin: 10px 0; }
    .dh-head { display: flex; align-items: center; gap: 8px; }
    .dh-head h3 { display: flex; align-items: center; gap: 6px; margin: 0; font-size: 16px; }
    .dh-sp { flex: 1; }
    .dh-dim { opacity: .7; font-size: 12px; }
    .dh-err { color: var(--bm-red, #c62828); margin: 6px 0; }
    .dh-row { display: flex; align-items: baseline; gap: 10px; border-top: 1px solid var(--bm-border, #eee);
              padding: 7px 0; font-size: 13px; text-decoration: none; color: inherit; cursor: pointer; }
    .dh-row:hover { background: color-mix(in srgb, var(--bm-accent, #1565c0) 6%, transparent); }
    .dh-at { font-size: 12px; opacity: .8; white-space: nowrap; }
    .dh-target { font-weight: 500; }
    .dh-cert { font-size: 11px; font-weight: 600; padding: 1px 8px; border-radius: 10px; white-space: nowrap; }
    .dh-cert--proven { background: color-mix(in srgb, var(--bm-green, #2e7d32) 24%, transparent); }
    .dh-cert--likely { background: color-mix(in srgb, var(--bm-amber, #ef6c00) 26%, transparent); }
    .dh-cert--unknown { background: color-mix(in srgb, var(--bm-dim, #888) 26%, transparent); }
    .dh-viol { font-size: 11px; font-weight: 600; color: var(--bm-red, #c62828); }
    .dh-summary { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 420px; }
    .dh-go { margin-left: auto; opacity: .5; }
  `],
})
export class DiagnosisHistoryComponent {
  private http = inject(HttpClient);
  agentId = input.required<string>();
  host = input<string>('this host');
  closed = output<void>();

  items = signal<HistoryItem[] | null>(null);
  busy = signal(false);
  error = signal('');

  constructor() {
    effect(() => { if (this.agentId()) this.load(); });
  }

  load(): void {
    this.busy.set(true); this.error.set('');
    this.http.get<{ items: HistoryItem[] }>(`${environment.apiUrl}/agents/${this.agentId()}/diagnoses?limit=50`).subscribe({
      next: (r) => { this.busy.set(false); this.items.set(r.items ?? []); },
      error: (e) => { this.busy.set(false); this.items.set(null); this.error.set(e?.error?.detail ?? e.message); },
    });
  }
}
