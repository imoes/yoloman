import { Component, computed, inject, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { environment } from '../../../environments/environment';

interface ProposalRow {
  id: string;
  kind: string;
  host: string;
  title: string;
  requested_by: string | null;
  status: string;              // pending | approved | rejected | applied | failed
  created_at: string;
  decided_by: string | null;
  decided_at: string | null;
}
interface ProposalDetail extends ProposalRow {
  payload: Record<string, unknown>;
  preview: Record<string, unknown>;
  apply_result: Record<string, unknown>;
}

/**
 * Change proposals (Agentic-OS governance) — the human-in-the-loop approval
 * queue for autonomous (AI-decided) changes. The AI files a proposal carrying
 * the dry-run PREVIEW (the diff) instead of writing directly; a human reviews it
 * here and approves (→ apply) or rejects. Answers "what would the AI change, and
 * do I allow it?" before anything touches a host.
 */
@Component({
  selector: 'app-proposals',
  standalone: true,
  imports: [MatIconModule, MatButtonModule],
  template: `
    <div class="pr">
      <div class="pr-hd">
        <h1>Change proposals</h1>
        <div class="pr-seg">
          @for (f of filters; track f.key) {
            <button class="pr-segbtn" [class.on]="filter() === f.key" (click)="setFilter(f.key)">{{ f.label }}</button>
          }
          <button mat-stroked-button (click)="reload()" [disabled]="busy()"><mat-icon>refresh</mat-icon></button>
        </div>
      </div>
      <p class="pr-dim">AI-decided changes land here as a dry-run preview — nothing touches a host until a human approves. (In YOLO mode the AI applies directly and nothing queues here.)</p>

      <div class="pr-body">
        <div class="pr-list">
          @for (p of rows(); track p.id) {
            <div class="pr-row" [class.sel]="selected()?.id === p.id" (click)="select(p)">
              <span class="pr-badge" [class]="'st-' + p.status">{{ p.status }}</span>
              <div class="pr-main">
                <div class="pr-title">{{ p.title }}</div>
                <div class="pr-sub">
                  <mat-icon class="pr-i">dns</mat-icon>{{ p.host }}
                  <span class="pr-who" [class.ai]="isAi(p.requested_by)"><mat-icon class="pr-i">{{ isAi(p.requested_by) ? 'smart_toy' : 'person' }}</mat-icon>{{ who(p.requested_by) }}</span>
                  <span class="pr-when">{{ when(p.created_at) }}</span>
                </div>
              </div>
            </div>
          } @empty { <p class="pr-dim">No proposals match.</p> }
        </div>

        <div class="pr-detail">
          @if (detail(); as d) {
            <div class="pr-dhd">
              <span class="pr-badge big" [class]="'st-' + d.status">{{ d.status }}</span>
              <h2>{{ d.title }}</h2>
            </div>
            <div class="pr-meta">
              <span><mat-icon class="pr-i">dns</mat-icon>{{ d.host }}</span>
              <span [class.ai]="isAi(d.requested_by)"><mat-icon class="pr-i">{{ isAi(d.requested_by) ? 'smart_toy' : 'person' }}</mat-icon>{{ who(d.requested_by) }}</span>
              <span><mat-icon class="pr-i">schedule</mat-icon>{{ when(d.created_at) }}</span>
              @if (d.decided_by) { <span><mat-icon class="pr-i">gavel</mat-icon>{{ d.status }} by {{ d.decided_by }}</span> }
            </div>

            @if (d.status === 'pending') {
              <div class="pr-actions">
                <button mat-flat-button color="primary" (click)="approve(d)" [disabled]="busy()"><mat-icon>check</mat-icon> Approve & apply</button>
                <button mat-stroked-button color="warn" (click)="reject(d)" [disabled]="busy()"><mat-icon>close</mat-icon> Reject</button>
              </div>
            }

            <h3>Preview (dry run)</h3>
            <pre class="pr-json">{{ json(d.preview) }}</pre>

            @if (d.apply_result && objKeys(d.apply_result).length) {
              <h3>Apply result</h3>
              <pre class="pr-json" [class.err]="d.status === 'failed'">{{ json(d.apply_result) }}</pre>
            }

            <details class="pr-payload">
              <summary>Payload (what would be written)</summary>
              <pre class="pr-json">{{ json(d.payload) }}</pre>
            </details>
          } @else { <p class="pr-dim">Pick a proposal to review its preview.</p> }
        </div>
      </div>
    </div>
  `,
  styles: [`
    .pr { padding: 18px 22px; }
    .pr-hd { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
    .pr-hd h1 { margin: 0; }
    .pr-seg { display: flex; align-items: center; gap: 8px; }
    .pr-segbtn { border: 1px solid var(--mat-sys-outline-variant); background: transparent; color: inherit; padding: 5px 12px; border-radius: 8px; cursor: pointer; font-size: 12.5px; }
    .pr-segbtn.on { background: color-mix(in srgb, var(--mat-sys-primary) 18%, transparent); }
    .pr-dim { opacity: 0.6; font-size: 13px; }
    .pr-body { display: flex; gap: 16px; align-items: flex-start; }
    .pr-list { flex: 0 0 400px; max-width: 440px; display: flex; flex-direction: column; gap: 6px; max-height: calc(100vh - 220px); overflow: auto; }
    .pr-row { display: flex; gap: 10px; align-items: center; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 8px 10px; cursor: pointer; }
    .pr-row:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
    .pr-row.sel { border-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
    .pr-main { min-width: 0; flex: 1; }
    .pr-title { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .pr-sub { display: flex; align-items: center; gap: 10px; font-size: 11.5px; opacity: 0.75; margin-top: 2px; flex-wrap: wrap; }
    .pr-who.ai { color: #7c4dff; font-weight: 600; opacity: 1; }
    .pr-when { margin-left: auto; }
    .pr-badge { font-size: 10.5px; font-weight: 700; text-transform: uppercase; padding: 2px 8px; border-radius: 10px; flex: 0 0 auto; letter-spacing: .3px; }
    .pr-badge.big { font-size: 12px; padding: 3px 12px; }
    .st-pending { background: color-mix(in srgb, #f9a825 30%, transparent); color: #7a5300; }
    .st-approved, .st-applied { background: color-mix(in srgb, #2e7d32 22%, transparent); color: #1b5e20; }
    .st-rejected, .st-failed { background: color-mix(in srgb, #e53935 30%, transparent); color: #8e0000; }
    @media (prefers-color-scheme: dark) { .st-pending{color:#ffd54f} .st-approved,.st-applied{color:#a5d6a7} .st-rejected,.st-failed{color:#ff8a80} }
    .pr-detail { flex: 1; min-width: 0; }
    .pr-dhd { display: flex; align-items: center; gap: 10px; } .pr-dhd h2 { margin: 0; }
    .pr-meta { display: flex; gap: 16px; font-size: 12.5px; opacity: 0.8; margin: 6px 0 4px; flex-wrap: wrap; align-items: center; }
    .pr-meta .ai { color: #7c4dff; font-weight: 600; opacity: 1; }
    .pr-i { font-size: 15px; height: 15px; width: 15px; vertical-align: -2px; margin-right: 3px; opacity: .8; }
    .pr-actions { display: flex; gap: 10px; margin: 10px 0; }
    .pr-json { padding: 8px; background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); border-radius: 6px; font-size: 11.5px; white-space: pre-wrap; overflow-wrap: anywhere; max-height: 360px; overflow: auto; }
    .pr-json.err { background: color-mix(in srgb, #e53935 12%, transparent); }
    .pr-payload { margin-top: 10px; } .pr-payload summary { cursor: pointer; font-size: 13px; opacity: .8; }
  `],
})
export class ProposalsComponent {
  private http = inject(HttpClient);
  filters = [
    { key: 'pending', label: 'Pending' },
    { key: '', label: 'All' },
    { key: 'applied', label: 'Applied' },
    { key: 'rejected', label: 'Rejected' },
  ];
  rows = signal<ProposalRow[]>([]);
  selected = signal<ProposalRow | null>(null);
  detail = signal<ProposalDetail | null>(null);
  filter = signal('pending');
  busy = signal(false);

  constructor() { this.reload(); }

  reload(): void {
    this.busy.set(true);
    const q = this.filter() ? `?status=${this.filter()}` : '';
    this.http.get<{ proposals: ProposalRow[] }>(`${environment.apiUrl}/change-proposals${q}`).subscribe({
      next: (r) => { this.rows.set(r.proposals); this.busy.set(false); },
      error: () => this.busy.set(false),
    });
  }
  setFilter(k: string): void { this.filter.set(k); this.reload(); }
  select(p: ProposalRow): void {
    this.selected.set(p); this.detail.set(null);
    this.http.get<ProposalDetail>(`${environment.apiUrl}/change-proposals/${p.id}`).subscribe((d) => this.detail.set(d));
  }
  approve(d: ProposalDetail): void {
    if (!confirm(`Approve and APPLY "${d.title}" on ${d.host}?`)) return;
    this.busy.set(true);
    this.http.post<ProposalDetail>(`${environment.apiUrl}/change-proposals/${d.id}/approve`, {}).subscribe({
      next: (r) => { this.busy.set(false); this.detail.set(r); this.reload(); },
      error: (e) => { this.busy.set(false); alert(e?.error?.detail || 'approve failed'); },
    });
  }
  reject(d: ProposalDetail): void {
    this.busy.set(true);
    this.http.post<ProposalDetail>(`${environment.apiUrl}/change-proposals/${d.id}/reject`, {}).subscribe({
      next: (r) => { this.busy.set(false); this.detail.set(r); this.reload(); },
      error: (e) => { this.busy.set(false); alert(e?.error?.detail || 'reject failed'); },
    });
  }

  isAi(w: string | null): boolean { return !!w && w.startsWith('ai:'); }
  who(w: string | null): string { return w ? (w.startsWith('ai:') ? 'AI · ' + w.slice(3) : w) : 'system'; }
  when(iso: string): string { try { return new Date(iso).toLocaleString(); } catch { return iso; } }
  json(o: unknown): string { try { return JSON.stringify(o, null, 2); } catch { return String(o); } }
  objKeys(o: Record<string, unknown> | null | undefined): string[] { return o ? Object.keys(o) : []; }
}
