import { Component, effect, inject, input, output, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { RouterLink } from '@angular/router';
import { environment } from '../../../environments/environment';
import { BlockedReasonDirective } from '../../shared/blocked-reason/blocked-reason.directive';
import { GraylogSettings, SystemSettingsService } from '../../core/services/system-settings.service';

interface Evidence { id: string; source: string; observed: string | null; fact: string; raw: unknown }
interface Finding {
  rule_id: string; claim: string; certainty: 'Proven' | 'Likely' | 'Unknown'; evidence_ids: string[];
  precedent: { evidence_id: string; change: string; observed: string; gap_seconds: number } | null;
  remedy: { action: string; target: { kind: string; id: string; attribute: string | null }; before: unknown; after: unknown;
            rollback: { action: string; value: unknown }; verify: { rule_absent: string; expect: unknown } } | null;
  gap: string | null;
}
interface DiagnosisDoc {
  diagnosis_id: string; host: string; platform: string; target: { name: string; display_name?: string | null };
  status: string; summary: string; evidence: Evidence[]; findings: Finding[];
  timeline: { observed: string; evidence_id: string }[]; gaps: { what: string; why: string }[];
}
interface StoredDiagnosis { id: string; contract_status: 'ok' | 'violation'; contract_violations: string[]; diagnosis: DiagnosisDoc }
interface Explanation { source: string; note: string | null; header: string[]; unbacked: number;
                        sentences: { text: string; evidence_ids: string[]; backed: boolean; why: string | null }[] }
interface RelatedItem { id: string; host: string; target: { name: string } | null; collected_at: string;
                        contract_status: 'ok' | 'violation' }
interface ProposalRef { id: string; title: string; status: string; requested_by: string | null;
                        decided_by: string | null; created_at: string }

/**
 * "Why is it not running?" — one diagnosis, rendered (docs/diagnosis.md).
 *
 * Everything shown comes from the agent's document through Bossman's diagnosis endpoints (asked, re-checked, kept);
 * nothing here decides. The certainty is the finding's own word, the evidence behind each claim opens on demand,
 * a precedent is labelled a correlation, a gap is said, and an explanation sentence the evidence does not back is
 * marked so — not hidden. A repair is offered as a PROPOSAL (four-eyes, never executed here) and as exports.
 */
@Component({
  selector: 'app-diagnosis-panel',
  standalone: true,
  imports: [MatButtonModule, MatIconModule, BlockedReasonDirective, RouterLink],
  template: `
    <section class="dg" [attr.data-service]="service()">
      <header class="dg-head">
        <h3><mat-icon>troubleshoot</mat-icon> Why is {{ subject() }} not running?</h3>
        <span class="dg-sp"></span>
        @if (storedId()) {
          <span class="dg-dim" title="A saved diagnosis, shown as it was recorded">kept {{ collectedAt() }}</span>
        } @else {
          <button mat-stroked-button (click)="load()" [disabled]="busy()"><mat-icon>refresh</mat-icon> Diagnose again</button>
        }
        <button mat-icon-button aria-label="Close" (click)="closed.emit()"><mat-icon>close</mat-icon></button>
      </header>

      @if (busy()) { <p class="dg-dim">{{ storedId() ? 'Loading the saved diagnosis…' : "Asking " + service() + "'s host…" }}</p> }
      @if (error()) { <p class="dg-err">{{ error() }}</p> }

      @if (stored(); as s) {
        @let d = s.diagnosis;
        @if (s.contract_status === 'violation') {
          <div class="dg-err">This diagnosis does not hold the contract and is shown as the agent sent it:
            {{ s.contract_violations.join('; ') }}</div>
        }
        <p class="dg-summary"><span class="dg-status">{{ d.status }}</span> {{ d.summary }}</p>

        <div class="dg-actions dg-top-actions">
          <span class="bm-why">
            <button mat-stroked-button (click)="sendGelf()" [disabled]="sending()"
                    [bmBlocked]="gelfBlocked()">
              <mat-icon>send</mat-icon> {{ sending() ? 'Sending…' : 'Send to Graylog' }}</button>
          </span>
          @if (sentGelf(); as msg) { <span class="dg-dim" [class.dg-err]="sendFailed()">{{ msg }}</span> }
        </div>

        @if (related().length) {
          <details class="dg-related">
            <summary><mat-icon>history</mat-icon> Seen before — same failure elsewhere or earlier ({{ related().length }})</summary>
            @for (r of related(); track r.id) {
              <a class="dg-relrow" [routerLink]="['/diagnoses', r.id]">
                <code class="dg-dim">{{ r.collected_at }}</code>
                <span class="dg-relhost">{{ r.host }}</span>
                <span class="dg-dim">{{ r.target?.name }}</span>
                @if (r.contract_status === 'violation') { <span class="dg-relviol">violation</span> }
              </a>
            }
          </details>
        }

        @if (proposals().length) {
          <div class="dg-proposals">
            <mat-icon>gavel</mat-icon> Remedy proposed for this diagnosis:
            @for (p of proposals(); track p.id) {
              <a class="dg-proprow" routerLink="/change-proposals" [title]="p.title">
                <span class="dg-propstat dg-propstat--{{ p.status }}">{{ p.status }}</span>
                <span class="dg-dim">{{ p.decided_by ? 'by ' + p.decided_by : (p.requested_by || '') }}</span>
              </a>
            }
          </div>
        }

        @for (f of d.findings; track $index; let i = $index) {
          <article class="dg-finding" [attr.data-rule]="f.rule_id">
            <div class="dg-fhead">
              <span class="dg-cert dg-cert--{{ f.certainty.toLowerCase() }}"
                    [attr.title]="certaintyHelp[f.certainty]">{{ f.certainty }}</span>
              <span class="dg-claim">{{ f.claim }}</span>
            </div>
            <div class="dg-rule dg-dim">{{ f.rule_id }}</div>
            @if (f.gap) { <p class="dg-gap"><mat-icon>help_outline</mat-icon> Not measurable: {{ f.gap }}</p> }
            @if (f.precedent; as p) {
              <p class="dg-prec"><mat-icon>history</mat-icon> {{ secs(p.gap_seconds) }} before: {{ p.change }}
                <span class="dg-dim">— a correlation, not a cause</span></p>
            }
            <details class="dg-ev">
              <summary>Evidence ({{ f.evidence_ids.length }})</summary>
              @for (id of f.evidence_ids; track id) {
                @if (ev(d, id); as e) {
                  <div class="dg-evrow"><code>{{ e.id }}</code> <span class="dg-dim">{{ e.source }}{{ e.observed ? ' · ' + e.observed : '' }}</span>
                    <div>{{ e.fact }}</div></div>
                }
              }
            </details>
            @if (f.remedy; as r) {
              <div class="dg-remedy">
                <div><strong>Repair:</strong> {{ r.action }} {{ r.target.kind }} <code>{{ r.target.id }}</code>
                  — now <code>{{ show(r.before) }}</code>, after <code>{{ show(r.after) }}</code>;
                  undo: {{ r.rollback.action }} <code>{{ show(r.rollback.value) }}</code>;
                  checked by a new diagnosis without <code>{{ r.verify.rule_absent }}</code>.</div>
                <div class="dg-actions">
                  <span class="bm-why" [attr.title]="proposeBlocked(s) || null">
                    <button mat-stroked-button (click)="propose(i)" [disabled]="!!proposeBlocked(s)">
                      <mat-icon>gavel</mat-icon> Propose this repair</button></span>
                  @for (fmt of exportFormats; track fmt) {
                    <button mat-button (click)="exportAs(fmt)">{{ fmt }}</button>
                  }
                </div>
              </div>
            }
          </article>
        } @empty {
          @if (d.status === 'running') { <p class="dg-dim">It is running — there is nothing to explain.</p> }
        }

        @if (proposed()) { <p class="dg-ok">{{ proposed() }}</p> }
        @if (exported(); as x) {
          <div class="dg-export">
            <div class="dg-dim">{{ x.format }}</div>
            @if (x.apply) { <pre>{{ x.apply }}</pre> }
            @if (x.rollback) { <div class="dg-dim">Rollback</div><pre>{{ x.rollback }}</pre> }
            @if (x.content) { <pre>{{ show(x.content) }}</pre> }
            @for (m of x.not_expressible || []; track m) { <p class="dg-dim">Not expressible: {{ m }}</p> }
            @if (x.note) { <p class="dg-dim">{{ x.note }}</p> }
          </div>
        }

        @if (d.gaps.length) {
          <h4>What could not be observed</h4>
          <ul class="dg-gaps">@for (g of d.gaps; track g.what) { <li><strong>{{ g.what }}</strong>: {{ g.why }}</li> }</ul>
        }

        <details class="dg-timeline">
          <summary>Timeline ({{ d.timeline.length }})</summary>
          @for (t of d.timeline; track t.evidence_id) {
            <div class="dg-trow"><code>{{ t.observed }}</code> {{ ev(d, t.evidence_id)?.fact }}</div>
          }
        </details>

        <div class="dg-explain">
          <button mat-stroked-button (click)="explain()" [disabled]="explaining()"><mat-icon>record_voice_over</mat-icon> Explain</button>
          @if (explanation(); as x) {
            <div class="dg-xbody" [attr.data-source]="x.source">
              @for (h of x.header; track $index) { <p class="dg-xhead">{{ h }}</p> }
              @for (sn of x.sentences; track $index) {
                <p class="dg-sent" [class.dg-unbacked]="!sn.backed" [attr.title]="sn.why || sn.evidence_ids.join(', ')">
                  {{ sn.text }} @if (!sn.backed) { <span class="dg-flag">not backed: {{ sn.why }}</span> }
                </p>
              }
              @if (x.note) { <p class="dg-dim">{{ x.note }}</p> }
            </div>
          }
        </div>
      }
    </section>
  `,
  styles: [`
    .dg { border: 1px solid var(--bm-border, #ccc); border-radius: 8px; padding: 10px 14px; margin: 10px 0; }
    .dg-head { display: flex; align-items: center; gap: 8px; }
    .dg-head h3 { display: flex; align-items: center; gap: 6px; margin: 0; font-size: 16px; }
    .dg-sp { flex: 1; }
    .dg-dim { opacity: .7; font-size: 12px; }
    .dg-err { color: var(--bm-red, #c62828); margin: 6px 0; }
    .dg-ok { color: var(--bm-green, #2e7d32); }
    .dg-summary { margin: 8px 0; }
    .dg-status { font-weight: 600; text-transform: uppercase; font-size: 11px; margin-right: 6px; }
    .dg-finding { border-top: 1px solid var(--bm-border, #ddd); padding: 8px 0; }
    .dg-fhead { display: flex; gap: 8px; align-items: baseline; }
    .dg-cert { font-size: 11px; font-weight: 600; padding: 1px 8px; border-radius: 10px; white-space: nowrap; }
    .dg-cert--proven { background: color-mix(in srgb, var(--bm-green, #2e7d32) 24%, transparent); }
    .dg-cert--likely { background: color-mix(in srgb, var(--bm-amber, #ef6c00) 26%, transparent); }
    .dg-cert--unknown { background: color-mix(in srgb, var(--bm-dim, #888) 26%, transparent); }
    .dg-gap, .dg-prec { display: flex; align-items: center; gap: 4px; margin: 4px 0; font-size: 13px; }
    .dg-gap mat-icon, .dg-prec mat-icon { font-size: 16px; width: 16px; height: 16px; }
    .dg-ev summary, .dg-timeline summary { cursor: pointer; font-size: 13px; }
    .dg-evrow, .dg-trow { font-size: 12px; margin: 4px 0 4px 12px; }
    .dg-remedy { background: color-mix(in srgb, var(--bm-accent, #1565c0) 6%, transparent); padding: 6px 8px; border-radius: 6px; font-size: 13px; }
    .dg-actions { display: flex; gap: 4px; flex-wrap: wrap; margin-top: 4px; align-items: center; }
    .dg-top-actions { margin: 8px 0; gap: 10px; }
    .dg-related { margin: 8px 0; font-size: 13px; }
    .dg-related > summary { cursor: pointer; display: flex; align-items: center; gap: 4px; }
    .dg-related > summary mat-icon { font-size: 16px; width: 16px; height: 16px; }
    .dg-relrow { display: flex; align-items: baseline; gap: 10px; padding: 4px 0 4px 18px; text-decoration: none; color: inherit; }
    .dg-relrow:hover { background: color-mix(in srgb, var(--bm-accent, #1565c0) 6%, transparent); }
    .dg-relhost { font-weight: 500; }
    .dg-relviol { font-size: 11px; font-weight: 600; color: var(--bm-red, #c62828); }
    .dg-proposals { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; margin: 8px 0; font-size: 13px; }
    .dg-proposals > mat-icon { font-size: 16px; width: 16px; height: 16px; }
    .dg-proprow { display: inline-flex; align-items: center; gap: 5px; text-decoration: none; color: inherit; }
    .dg-propstat { font-size: 11px; font-weight: 600; padding: 1px 8px; border-radius: 10px;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
    .dg-propstat--approved, .dg-propstat--applied { background: color-mix(in srgb, var(--bm-green, #2e7d32) 24%, transparent); }
    .dg-propstat--rejected, .dg-propstat--failed { background: color-mix(in srgb, var(--bm-red, #c62828) 22%, transparent); }
    .dg-export pre, .dg-xbody pre { max-height: 260px; overflow: auto; font-size: 12px; }
    .dg-xhead { font-weight: 600; font-size: 13px; margin: 4px 0; }
    .dg-sent { margin: 4px 0; }
    .dg-unbacked { text-decoration: underline wavy var(--bm-red, #c62828); }
    .dg-flag { font-size: 11px; color: var(--bm-red, #c62828); margin-left: 6px; text-decoration: none; display: inline-block; }
    .dg-gaps { font-size: 13px; }
  `],
})
export class DiagnosisPanelComponent {
  private http = inject(HttpClient);
  private systemSettings = inject(SystemSettingsService);
  // Fresh mode: agentId + service → ask the host now (POST /diagnose). Stored mode: storedId → load a kept
  // diagnosis by its id (GET /diagnoses/:id), the permalink view (UX concept #3). Exactly one mode is in play.
  agentId = input<string>('');
  service = input<string>('');
  storedId = input<string>('');
  closed = output<void>();

  readonly exportFormats = ['powershell', 'ansible', 'dsc', 'checkmk', 'gelf'];
  readonly certaintyHelp: Record<string, string> = {
    Proven: 'Read directly on the host',
    Likely: 'Inferred from what the host recorded',
    Unknown: 'Could not be measured — the gap says what is missing',
  };
  stored = signal<StoredDiagnosis | null>(null);
  busy = signal(false);
  error = signal('');
  proposed = signal('');
  exported = signal<any>(null);
  explanation = signal<Explanation | null>(null);
  explaining = signal(false);
  // "Send to Graylog": the GELF target is env-based and read-only; we fetch it so the button is greyed UP FRONT with
  // the reason when no target is set, rather than offered and then refused with a 422 after the click.
  graylog = signal<GraylogSettings | null>(null);
  sending = signal(false);
  sentGelf = signal('');
  sendFailed = signal(false);
  related = signal<RelatedItem[]>([]);
  proposals = signal<ProposalRef[]>([]);

  constructor() {
    // A new question is a new answer: a saved id loads that diagnosis; otherwise a new service (or host) asks again.
    effect(() => {
      if (this.storedId()) this.loadStored();
      else if (this.agentId() && this.service()) this.load();
    });
    this.systemSettings.getGraylog().subscribe({ next: (g) => this.graylog.set(g), error: () => this.graylog.set(null) });
  }

  /** Why "Send to Graylog" cannot run, or '' when it can — greyed up front, the reason shown. */
  gelfBlocked(): string {
    if (!this.stored()) return 'Load a diagnosis first';
    const g = this.graylog();
    if (g && !g.configured) return 'No Graylog target is configured (set BOSSMAN_GELF_HOST in Bossman) — see Settings';
    return '';
  }

  sendGelf(): void {
    const s = this.stored();
    if (!s || this.gelfBlocked()) return;
    this.sending.set(true); this.sentGelf.set(''); this.sendFailed.set(false);
    this.http.post<{ sent: number; transport: string }>(`${environment.apiUrl}/diagnoses/${s.id}/export/gelf/send`, {}).subscribe({
      next: (r) => { this.sending.set(false); this.sentGelf.set(`Sent ${r.sent} GELF message${r.sent === 1 ? '' : 's'} to ${r.transport}.`); },
      error: (e) => { this.sending.set(false); this.sendFailed.set(true); this.sentGelf.set(`Not sent: ${e?.error?.detail ?? e.message}`); },
    });
  }

  /** The service this diagnosis is about — the input in fresh mode, the kept document's target in stored mode. */
  subject(): string {
    return this.service() || this.stored()?.diagnosis?.target?.display_name || this.stored()?.diagnosis?.target?.name || 'the service';
  }
  collectedAt(): string { const d = this.stored()?.diagnosis as any; return d?.collected_at ?? ''; }

  private reset(): void {
    this.busy.set(true); this.error.set(''); this.proposed.set(''); this.exported.set(null); this.explanation.set(null);
    this.related.set([]);
    this.proposals.set([]);
  }

  load(): void {
    this.reset();
    this.http.post<StoredDiagnosis>(`${environment.apiUrl}/agents/${this.agentId()}/diagnose`,
      { name: this.service(), timeout_seconds: 120 }).subscribe({
      next: (s) => { this.busy.set(false); this.stored.set(s); this.loadRelated(s.id); },
      error: (e) => { this.busy.set(false); this.stored.set(null); this.error.set(e?.error?.detail ?? e.message); },
    });
  }

  loadStored(): void {
    this.reset();
    this.http.get<StoredDiagnosis>(`${environment.apiUrl}/diagnoses/${this.storedId()}`).subscribe({
      next: (s) => { this.busy.set(false); this.stored.set(s); this.loadRelated(s.id); },
      error: (e) => { this.busy.set(false); this.stored.set(null); this.error.set(e?.error?.detail ?? e.message); },
    });
  }

  /** Precedent: other diagnoses of the same failure mode across the fleet (best-effort — a failure to load it must not
   *  disturb the diagnosis itself). */
  private loadRelated(id: string): void {
    this.http.get<{ items: RelatedItem[] }>(`${environment.apiUrl}/diagnoses/${id}/related`).subscribe({
      next: (r) => this.related.set(r.items ?? []),
      error: () => this.related.set([]),
    });
    this.http.get<{ items: ProposalRef[] }>(`${environment.apiUrl}/diagnoses/${id}/proposals`).subscribe({
      next: (r) => this.proposals.set(r.items ?? []),
      error: () => this.proposals.set([]),
    });
  }

  ev(d: DiagnosisDoc, id: string): Evidence | undefined { return d.evidence.find((e) => e.id === id); }
  show(v: unknown): string { return typeof v === 'string' ? v : JSON.stringify(v, null, 2); }
  secs(n: number): string { return n < 120 ? `${n} s` : n < 7200 ? `${Math.round(n / 60)} min` : n < 172800 ? `${Math.round(n / 3600)} h` : `${Math.round(n / 86400)} days`; }

  proposeBlocked(s: StoredDiagnosis): string {
    return s.contract_status !== 'ok' ? 'A repair is not proposed from a diagnosis that does not hold the contract' : '';
  }

  propose(i: number): void {
    const s = this.stored(); if (!s) return;
    this.http.post<{ proposal_id: string; title: string }>(`${environment.apiUrl}/diagnoses/${s.id}/propose`, { finding: i }).subscribe({
      next: (r) => this.proposed.set(`Proposed: "${r.title}". A second person approves it under Change proposals — approving runs nothing.`),
      error: (e) => this.proposed.set(`Not proposed: ${e?.error?.detail ?? e.message}`),
    });
  }

  exportAs(fmt: string): void {
    const s = this.stored(); if (!s) return;
    this.http.get<any>(`${environment.apiUrl}/diagnoses/${s.id}/export/${fmt}`).subscribe({
      next: (x) => this.exported.set(x),
      error: (e) => this.exported.set({ format: fmt, note: e?.error?.detail ?? e.message }),
    });
  }

  explain(): void {
    const s = this.stored(); if (!s) return;
    this.explaining.set(true);
    this.http.get<Explanation>(`${environment.apiUrl}/diagnoses/${s.id}/explain`).subscribe({
      next: (x) => { this.explaining.set(false); this.explanation.set(x); },
      error: (e) => { this.explaining.set(false); this.error.set(e?.error?.detail ?? e.message); },
    });
  }
}
