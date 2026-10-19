import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { FormsModule } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { environment } from '../../../environments/environment';
import { downloadCsv } from '../../shared/csv';

interface DiagnosisRow {
  id: string; host: string; platform: string; target: { kind: string; name: string };
  status: string; summary: string; leading_rule: string | null;
  leading_certainty: 'Proven' | 'Likely' | 'Unknown' | null;
  contract_status: 'ok' | 'violation'; agent_version: string | null; collected_at: string;
}
interface RecurringItem { rule: string; count: number; hosts: number; violations: number; last_seen: string | null }

/**
 * The fleet-wide diagnoses board (admin). Every host's stored diagnoses, newest first — so a diagnosis is findable
 * across the fleet, not only host by host in the console. Read-only: each row links to the diagnosis at its own
 * permalink (/diagnoses/:id); contract violations are flagged; filters narrow by status, contract and free text.
 */
@Component({
  selector: 'app-diagnoses-board',
  standalone: true,
  imports: [FormsModule, RouterLink, MatButtonModule, MatIconModule],
  template: `
    <div class="bm-page">
      <div class="bm-head">
        <div>
          <h1>Diagnoses</h1>
          <p class="bm-dim">Every host's stored diagnoses, newest first — why a service did not run, or why a host is
            behind on updates. Read-only; each opens at its own link. A document that did not hold the contract is
            flagged <strong>violation</strong> and shown as the agent sent it.</p>
        </div>
        <span class="bm-why" [attr.title]="rows().length ? null : 'Nothing to export'">
          <button mat-stroked-button (click)="exportCsv()" [disabled]="!rows().length"><mat-icon>download</mat-icon> Export CSV</button>
        </span>
      </div>

      <div class="bm-filters">
        <input placeholder="host / service / rule" aria-label="Search host, service or rule" [(ngModel)]="fq" (keyup.enter)="reload()" />
        <select [(ngModel)]="fStatus" (ngModelChange)="reload()" aria-label="Status">
          <option value="">any status</option>
          <option value="running">running</option><option value="failed">failed</option>
          <option value="behind">behind</option><option value="up-to-date">up-to-date</option>
        </select>
        <select [(ngModel)]="fContract" (ngModelChange)="reload()" aria-label="Contract">
          <option value="">any contract</option>
          <option value="ok">ok</option><option value="violation">violation</option>
        </select>
        <button mat-stroked-button (click)="reload()"><mat-icon>search</mat-icon> Search</button>
      </div>

      @if (!loading() && !err() && rows().length) {
        @let s = summary();
        <div class="db-summary">
          <span class="db-chip">{{ s.total }} shown</span>
          @if (s.notOk) { <span class="db-chip db-chip--bad">{{ s.notOk }} not OK</span> }
          @if (s.violations) { <span class="db-chip db-chip--bad">{{ s.violations }} violation{{ s.violations === 1 ? '' : 's' }}</span> }
          @if (s.proven) { <span class="db-chip">{{ s.proven }} Proven</span> }
          @if (s.likely) { <span class="db-chip">{{ s.likely }} Likely</span> }
          @if (s.unknown) { <span class="db-chip">{{ s.unknown }} Unknown</span> }
          <span class="db-chip bm-dim">{{ s.hosts }} host{{ s.hosts === 1 ? '' : 's' }}</span>
        </div>
      }

      @if (recurring().length) {
        <details class="db-recurring">
          <summary>What keeps breaking — recurring failure modes ({{ recurring().length }})</summary>
          <div class="db-recur-list">
            @for (r of recurring(); track r.rule) {
              <button class="db-recur" [class.db-recur--on]="fq === r.rule" (click)="drillInto(r.rule)"
                      [title]="'filter to ' + r.rule">
                <code>{{ r.rule }}</code>
                <span class="db-dim">×{{ r.count }} · {{ r.hosts }} host{{ r.hosts === 1 ? '' : 's' }}@if (r.violations) { · {{ r.violations }} viol}</span>
              </button>
            }
          </div>
        </details>
      }

      @if (loading()) { <p class="bm-dim">Loading…</p> }
      @else if (err()) { <p class="bm-err">{{ err() }}</p> }
      @else {
        @for (r of rows(); track r.id) {
          <a class="dh-row" [routerLink]="['/diagnoses', r.id]" [attr.data-id]="r.id">
            <code class="dh-at">{{ r.collected_at }}</code>
            <span class="dh-host">{{ r.host }}</span>
            <span class="dh-target">{{ r.target.name || r.target.kind }}</span>
            @if (r.leading_certainty) {
              <span class="dh-cert dh-cert--{{ r.leading_certainty.toLowerCase() }}">{{ r.leading_certainty }}</span>
            }
            <span class="dh-rule bm-dim">{{ r.leading_rule || r.status }}</span>
            @if (r.contract_status === 'violation') { <span class="dh-viol" title="Did not hold the contract">violation</span> }
            <span class="dh-summary bm-dim">{{ r.summary }}</span>
            <mat-icon class="dh-go">chevron_right</mat-icon>
          </a>
        } @empty { <p class="bm-dim">No diagnoses stored yet (or none match the filters). Run "Why is it not running?" on a service.</p> }
      }
    </div>
  `,
  styles: [`
    .bm-page { padding: 24px; max-width: 1100px; margin: 0 auto; }
    .bm-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; margin-bottom: 12px; }
    .bm-head h1 { margin: 0 0 4px; }
    .bm-head p { margin: 0; max-width: 760px; font-size: 13px; line-height: 1.5; }
    .bm-dim { opacity: 0.65; font-size: 12.5px; }
    .bm-err { color: var(--bm-red, #c62828); }
    .bm-filters { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 14px; align-items: center; }
    .bm-filters input, .bm-filters select { padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant);
      background: var(--mat-sys-surface); color: inherit; font: inherit; font-size: 13px; }
    .bm-filters input { min-width: 200px; }
    .dh-row { display: flex; align-items: baseline; gap: 10px; border-top: 1px solid var(--mat-sys-outline-variant);
              padding: 8px 0; font-size: 13px; text-decoration: none; color: inherit; }
    .dh-row:hover { background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent); }
    .dh-at { font-size: 12px; opacity: .8; white-space: nowrap; }
    .dh-host { font-weight: 600; min-width: 140px; }
    .dh-target { font-weight: 500; }
    .dh-cert { font-size: 11px; font-weight: 600; padding: 1px 8px; border-radius: 10px; white-space: nowrap; }
    .dh-cert--proven { background: color-mix(in srgb, var(--bm-green, #2e7d32) 24%, transparent); }
    .dh-cert--likely { background: color-mix(in srgb, var(--bm-amber, #ef6c00) 26%, transparent); }
    .dh-cert--unknown { background: color-mix(in srgb, var(--bm-dim, #888) 26%, transparent); }
    .dh-viol { font-size: 11px; font-weight: 600; color: var(--bm-red, #c62828); }
    .dh-summary { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 360px; }
    .dh-go { margin-left: auto; opacity: .5; }
    .db-summary { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 12px; }
    .db-chip { font-size: 12px; font-weight: 600; padding: 3px 10px; border-radius: 12px;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .db-chip--bad { background: color-mix(in srgb, var(--bm-red, #c62828) 20%, transparent); }
    .db-recurring { margin-bottom: 12px; font-size: 13px; }
    .db-recurring > summary { cursor: pointer; }
    .db-recur-list { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 8px; }
    .db-recur { display: inline-flex; align-items: center; gap: 6px; padding: 4px 10px; border-radius: 8px; cursor: pointer;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font: inherit; font-size: 12.5px; }
    .db-recur:hover { background: color-mix(in srgb, var(--mat-sys-primary) 8%, transparent); }
    .db-recur--on { border-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 14%, transparent); }
    .db-dim { opacity: 0.7; }
  `],
})
export class DiagnosesBoardComponent implements OnInit {
  private http = inject(HttpClient);
  rows = signal<DiagnosisRow[]>([]);
  loading = signal(true);
  err = signal('');
  fq = '';
  fStatus = '';
  fContract = '';
  recurring = signal<RecurringItem[]>([]);

  /** At-a-glance counts over the loaded rows — total, how many are not OK / in violation, by certainty, host count. */
  summary = computed(() => {
    const rows = this.rows();
    return {
      total: rows.length,
      notOk: rows.filter((r) => r.status !== 'running' && r.status !== 'up-to-date' && r.status !== 'ok').length,
      violations: rows.filter((r) => r.contract_status === 'violation').length,
      proven: rows.filter((r) => r.leading_certainty === 'Proven').length,
      likely: rows.filter((r) => r.leading_certainty === 'Likely').length,
      unknown: rows.filter((r) => r.leading_certainty === 'Unknown').length,
      hosts: new Set(rows.map((r) => r.host)).size,
    };
  });

  ngOnInit(): void {
    this.reload();
    // Fleet-wide "what keeps breaking" — independent of the row filters; best-effort.
    this.http.get<{ items: RecurringItem[] }>(`${environment.apiUrl}/diagnoses/recurring?limit=12`).subscribe({
      next: (r) => this.recurring.set(r.items ?? []),
      error: () => this.recurring.set([]),
    });
  }

  /** Drill a recurring failure mode into the list below (filter to that rule). */
  drillInto(rule: string): void { this.fq = this.fq === rule ? '' : rule; this.reload(); }

  reload(): void {
    this.loading.set(true); this.err.set('');
    let p = new HttpParams().set('limit', '200');
    if (this.fq) p = p.set('q', this.fq);
    if (this.fStatus) p = p.set('status', this.fStatus);
    if (this.fContract) p = p.set('contract_status', this.fContract);
    this.http.get<{ items: DiagnosisRow[] }>(`${environment.apiUrl}/diagnoses`, { params: p }).subscribe({
      next: (r) => { this.loading.set(false); this.rows.set(r.items ?? []); },
      error: (e) => { this.loading.set(false); this.rows.set([]); this.err.set(e?.error?.detail ?? e.message); },
    });
  }

  exportCsv(): void {
    downloadCsv('diagnoses.csv',
      ['collected_at', 'host', 'platform', 'target', 'status', 'leading_rule', 'certainty', 'contract', 'summary'],
      this.rows().map((r) => [r.collected_at, r.host, r.platform, r.target.name || r.target.kind, r.status,
                              r.leading_rule ?? '', r.leading_certainty ?? '', r.contract_status, r.summary]));
  }
}
