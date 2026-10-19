import { Component, effect, inject, input, output, signal } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { environment } from '../../../environments/environment';

interface Incident {
  kind: string; at: string; pid: number; image: string; source: string; evidence_id: string; detail?: string;
}
interface Ring {
  host: string; agent_version: string | null; source: string; persistent: boolean; since: string;
  capacity: number; ring_state: string; count: number; incidents: Incident[];
}

/**
 * The host's recent PAST incidents, as a timeline (docs/diagnosis.md, peer UX concept #2).
 *
 * A LIVE read of the agent's incident ring — the same crashes/OOM-kills a diagnosis cites as svc.recent_incident —
 * so nothing is stored. The honesty is in the envelope, shown up front: ring_state (available | not_supported),
 * since (when capture began), capacity and whether it survives a reboot. An empty list is "nothing the ring holds",
 * never dressed up as "no crashes", and an agent too old to answer is the host's own named refusal.
 */
@Component({
  selector: 'app-incident-timeline',
  standalone: true,
  imports: [MatButtonModule, MatIconModule],
  template: `
    <section class="it">
      <header class="it-head">
        <h3><mat-icon>timeline</mat-icon> Recent incidents on {{ host() }}</h3>
        <span class="it-sp"></span>
        <label class="it-dim">last
          <select [value]="within()" (change)="setWithin($any($event.target).value)">
            <option value="0">all the ring holds</option>
            <option value="60">60 min</option>
            <option value="360">6 h</option>
            <option value="1440">24 h</option>
          </select>
        </label>
        <button mat-stroked-button (click)="load()" [disabled]="busy()"><mat-icon>refresh</mat-icon> Refresh</button>
        <button mat-icon-button aria-label="Close" (click)="closed.emit()"><mat-icon>close</mat-icon></button>
      </header>

      @if (busy()) { <p class="it-dim">Reading {{ host() }}'s incident ring…</p> }
      @if (error()) { <p class="it-err">{{ error() }}</p> }

      @if (ring(); as r) {
        <!-- THE RING STATE FIRST, so an empty list is never read as "nothing ever crashed". -->
        @if (available(r)) {
          <p class="it-meta it-ok"><mat-icon>check_circle</mat-icon>
            Ring live since <code>{{ r.since }}</code> · holds up to {{ r.capacity }} ·
            {{ r.persistent ? 'survives a reboot' : 'in-memory — cleared on an agent restart' }} ·
            {{ r.count }} shown. An empty list means no incidents the ring holds, not a guarantee nothing crashed.</p>
        } @else {
          <p class="it-meta it-warn"><mat-icon>help_outline</mat-icon> {{ r.ring_state }}</p>
        }

        @for (inc of r.incidents; track inc.evidence_id) {
          <article class="it-row" [attr.data-kind]="inc.kind">
            <span class="it-kind it-kind--{{ kindClass(inc.kind) }}">{{ inc.kind }}</span>
            <code class="it-at">{{ inc.at }}</code>
            <span class="it-img">{{ inc.image }} <span class="it-dim">· pid {{ inc.pid }}</span></span>
            @if (inc.detail) { <span class="it-detail">{{ inc.detail }}</span> }
            <code class="it-ev it-dim" [attr.title]="'cited by a diagnosis as ' + inc.evidence_id">{{ inc.evidence_id }}</code>
          </article>
        } @empty {
          @if (available(r)) { <p class="it-dim">No incidents in this window.</p> }
        }
      }
    </section>
  `,
  styles: [`
    .it { border: 1px solid var(--bm-border, #ccc); border-radius: 8px; padding: 10px 14px; margin: 10px 0; }
    .it-head { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
    .it-head h3 { display: flex; align-items: center; gap: 6px; margin: 0; font-size: 16px; }
    .it-sp { flex: 1; }
    .it-dim { opacity: .7; font-size: 12px; }
    .it-err { color: var(--bm-red, #c62828); margin: 6px 0; }
    .it-meta { display: flex; align-items: center; gap: 6px; font-size: 12px; margin: 8px 0; }
    .it-meta mat-icon { font-size: 16px; width: 16px; height: 16px; }
    .it-ok { opacity: .85; }
    .it-warn { color: var(--bm-amber, #ef6c00); }
    .it-row { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; border-top: 1px solid var(--bm-border, #eee); padding: 6px 0; font-size: 13px; }
    .it-kind { font-size: 11px; font-weight: 600; padding: 1px 8px; border-radius: 10px; white-space: nowrap; }
    .it-kind--crash { background: color-mix(in srgb, var(--bm-red, #c62828) 22%, transparent); }
    .it-kind--exit { background: color-mix(in srgb, var(--bm-amber, #ef6c00) 24%, transparent); }
    .it-kind--other { background: color-mix(in srgb, var(--bm-dim, #888) 24%, transparent); }
    .it-at { font-size: 12px; opacity: .8; }
    .it-img { font-weight: 500; }
    .it-detail { font-size: 12px; }
    .it-ev { margin-left: auto; font-size: 11px; }
  `],
})
export class IncidentTimelineComponent {
  private http = inject(HttpClient);
  agentId = input.required<string>();
  host = input<string>('this host');
  closed = output<void>();

  ring = signal<Ring | null>(null);
  busy = signal(false);
  error = signal('');
  within = signal(0);

  constructor() {
    // A new host is a new ring: read it, drop the previous answer.
    effect(() => { if (this.agentId()) this.load(); });
  }

  available(r: Ring): boolean { return r.ring_state === 'available'; }

  kindClass(kind: string): string {
    if (kind === 'image-crash' || kind === 'oom-kill' || kind === 'fatal-signal') return 'crash';
    if (kind === 'process-exit') return 'exit';
    return 'other';
  }

  setWithin(value: string): void { this.within.set(Number(value) || 0); this.load(); }

  load(): void {
    this.busy.set(true); this.error.set('');
    let params = new HttpParams().set('limit', '200');
    if (this.within() > 0) params = params.set('within_minutes', String(this.within()));
    this.http.get<Ring>(`${environment.apiUrl}/agents/${this.agentId()}/incidents`, { params }).subscribe({
      next: (r) => { this.busy.set(false); this.ring.set(r); },
      error: (e) => { this.busy.set(false); this.ring.set(null); this.error.set(e?.error?.detail ?? e.message); },
    });
  }
}
