import { Component, computed, inject, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { FormsModule } from '@angular/forms';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { environment } from '../../../environments/environment';
import { AuthService } from '../../core/auth/auth.service';

interface RunRow {
  id: string;
  runbook_name: string;
  agent_id: string | null;
  host: string | null;
  status: string;             // ok | failed | aborted
  effect: string;             // changed | failed | unchanged
  dry_run: boolean;
  changed: boolean;
  requested_by: string | null;
  created_at: string;
}
interface StepResult {
  name: string;
  module: string;
  status: string;             // ok | changed | skipped | failed
  changed?: boolean | null;
  error?: string | null;
  item?: unknown;
  response?: Record<string, unknown>;
}
interface RunDetail extends RunRow {
  result: { check_mode?: boolean; ok?: boolean; changed?: boolean; aborted?: boolean; steps?: StepResult[]; facts_gathered?: number };
}

/**
 * Event Browser (gap #13) — every play (a runbook run) as a playbook-job row:
 * a changed / failed / unchanged badge, WHO ran it (incl. "ai:<user>" when the
 * AI was commissioned), when, and — on click — the engine's per-step JSON output
 * exactly like an Ansible play recap. Admins can purge history here; the
 * automatic retention window is set in Admin settings and shown in the toolbar.
 */
@Component({
  selector: 'app-event-browser',
  standalone: true,
  imports: [FormsModule, MatIconModule, MatButtonModule],
  template: `
    <div class="eb">
      <div class="eb-hd">
        <h1>Event Browser</h1>
        <div class="eb-tools">
          <input class="eb-search" type="search" placeholder="Filter by runbook or who…" [(ngModel)]="q" (keyup.enter)="reload()" />
          <div class="eb-seg">
            @for (f of effects; track f.key) {
              <button class="eb-segbtn" [class.on]="effect() === f.key" (click)="setEffect(f.key)">{{ f.label }}</button>
            }
          </div>
          <button mat-stroked-button (click)="reload()" [disabled]="busy()"><mat-icon>refresh</mat-icon></button>
        </div>
      </div>

      <div class="eb-retn">
        <mat-icon class="eb-i">history</mat-icon>
        <span>Auto-purge history older than</span>
        @if (isAdmin()) {
          <input class="eb-days" type="number" min="0" max="3650" [(ngModel)]="retentionEdit" />
          <span>days (0 = keep forever)</span>
          <button mat-stroked-button (click)="saveRetention()" [disabled]="busy() || retentionEdit === retention()">Save</button>
          <span class="eb-spacer"></span>
          <button mat-stroked-button color="warn" (click)="purge(retention())" [disabled]="busy() || !retention()"><mat-icon>auto_delete</mat-icon> Purge older than {{ retention() }}d</button>
          <button mat-stroked-button color="warn" (click)="purge(0)" [disabled]="busy()"><mat-icon>delete_forever</mat-icon> Clear all</button>
        } @else {
          <b>{{ retention() ? retention() + ' days' : 'forever' }}</b>
          <span class="eb-dim">(set in Admin settings)</span>
        }
        @if (msg()) { <span class="eb-ok">{{ msg() }}</span> }
      </div>

      <div class="eb-body">
        <div class="eb-list">
          @for (r of runs(); track r.id) {
            <div class="eb-row" [class.sel]="selected()?.id === r.id" (click)="select(r)">
              <span class="eb-badge" [class]="'ef-' + r.effect">{{ r.effect }}</span>
              <div class="eb-main">
                <div class="eb-name">{{ r.runbook_name }} @if (r.dry_run) { <span class="eb-dry">check</span> }</div>
                <div class="eb-sub">
                  <mat-icon class="eb-i">dns</mat-icon>{{ r.host || '—' }}
                  <span class="eb-who" [class.ai]="isAi(r.requested_by)"><mat-icon class="eb-i">{{ isAi(r.requested_by) ? 'smart_toy' : 'person' }}</mat-icon>{{ who(r.requested_by) }}</span>
                  <span class="eb-when">{{ when(r.created_at) }}</span>
                </div>
              </div>
            </div>
          } @empty { <p class="eb-dim">No events match.</p> }
        </div>

        <div class="eb-detail">
          @if (detail(); as d) {
            <div class="eb-dhd">
              <span class="eb-badge big" [class]="'ef-' + d.effect">{{ d.effect }}</span>
              <h2>{{ d.runbook_name }}</h2>
            </div>
            <div class="eb-meta">
              <span><mat-icon class="eb-i">dns</mat-icon>{{ d.host || '—' }}</span>
              <span [class.ai]="isAi(d.requested_by)"><mat-icon class="eb-i">{{ isAi(d.requested_by) ? 'smart_toy' : 'person' }}</mat-icon>{{ who(d.requested_by) }}</span>
              <span><mat-icon class="eb-i">schedule</mat-icon>{{ d.created_at }}</span>
              @if (d.dry_run) { <span class="eb-dry">check mode</span> }
            </div>

            <h3>Play recap <span class="eb-dim">({{ recap(d) }})</span></h3>
            <ol class="eb-steps">
              @for (s of d.result.steps || []; track $index) {
                <li>
                  <span class="eb-dot" [class]="'st-' + s.status" [title]="s.status"></span>
                  <div class="eb-stepbody">
                    <div class="eb-stephd" (click)="toggle($index)">
                      <span class="eb-stmod">{{ s.module }}</span>
                      <span class="eb-stname">{{ s.name }}</span>
                      <span class="eb-ststatus" [class]="'st-txt-' + s.status">{{ s.status }}</span>
                      <mat-icon class="eb-i">{{ open().has($index) ? 'expand_less' : 'expand_more' }}</mat-icon>
                    </div>
                    @if (open().has($index)) {
                      @if (s.error) { <pre class="eb-json err">{{ s.error }}</pre> }
                      @if (s.response) { <pre class="eb-json">{{ json(s.response) }}</pre> }
                    }
                  </div>
                </li>
              } @empty { <p class="eb-dim">No steps recorded.</p> }
            </ol>
          } @else { <p class="eb-dim">Pick an event on the left to see its play recap.</p> }
        </div>
      </div>
    </div>
  `,
  styles: [`
    .eb { padding: 18px 22px; }
    .eb-hd { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
    .eb-hd h1 { margin: 0; }
    .eb-tools { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
    .eb-search { padding: 6px 10px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; background: transparent; color: inherit; min-width: 220px; }
    .eb-seg { display: flex; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: hidden; }
    .eb-segbtn { border: 0; background: transparent; color: inherit; padding: 5px 12px; cursor: pointer; font-size: 12.5px; }
    .eb-segbtn.on { background: color-mix(in srgb, var(--mat-sys-primary) 18%, transparent); }
    .eb-retn { display: flex; align-items: center; gap: 8px; margin: 12px 0; font-size: 13px; opacity: 0.92; flex-wrap: wrap; }
    .eb-days { width: 64px; padding: 4px 6px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: transparent; color: inherit; }
    .eb-spacer { flex: 1; } .eb-dim { opacity: 0.6; }
    .eb-ok { color: var(--bm-green,#2e7d32); }
    .eb-body { display: flex; gap: 16px; align-items: flex-start; }
    .eb-list { flex: 0 0 420px; max-width: 460px; display: flex; flex-direction: column; gap: 6px; max-height: calc(100vh - 210px); overflow: auto; }
    .eb-row { display: flex; gap: 10px; align-items: center; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 8px 10px; cursor: pointer; }
    .eb-row:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
    .eb-row.sel { border-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
    .eb-main { min-width: 0; flex: 1; }
    .eb-name { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .eb-sub { display: flex; align-items: center; gap: 10px; font-size: 11.5px; opacity: 0.75; margin-top: 2px; flex-wrap: wrap; }
    .eb-who.ai { color: #7c4dff; font-weight: 600; opacity: 1; }
    .eb-when { margin-left: auto; }
    .eb-badge { font-size: 10.5px; font-weight: 700; text-transform: uppercase; padding: 2px 8px; border-radius: 10px; flex: 0 0 auto; letter-spacing: 0.3px; }
    .eb-badge.big { font-size: 12px; padding: 3px 12px; }
    .ef-changed { background: color-mix(in srgb, #f9a825 30%, transparent); color: #7a5300; }
    .ef-failed { background: color-mix(in srgb, #e53935 30%, transparent); color: #8e0000; }
    .ef-unchanged { background: color-mix(in srgb, #2e7d32 22%, transparent); color: #1b5e20; }
    @media (prefers-color-scheme: dark) { .ef-changed{color:#ffd54f} .ef-failed{color:#ff8a80} .ef-unchanged{color:#a5d6a7} }
    .eb-dry { font-size: 10px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 0 6px; opacity: 0.7; }
    .eb-detail { flex: 1; min-width: 0; }
    .eb-dhd { display: flex; align-items: center; gap: 10px; } .eb-dhd h2 { margin: 0; }
    .eb-meta { display: flex; gap: 16px; font-size: 12.5px; opacity: 0.8; margin: 6px 0 4px; flex-wrap: wrap; align-items: center; }
    .eb-meta .ai { color: #7c4dff; font-weight: 600; opacity: 1; }
    .eb-i { font-size: 15px; height: 15px; width: 15px; vertical-align: -2px; margin-right: 3px; opacity: 0.8; }
    .eb-steps { list-style: none; padding: 0; margin: 6px 0; }
    .eb-steps li { display: flex; gap: 10px; padding: 6px 0; border-top: 1px solid var(--mat-sys-outline-variant); }
    .eb-dot { width: 10px; height: 10px; border-radius: 50%; margin-top: 6px; flex: 0 0 auto; }
    .st-ok { background: #66bb6a; } .st-changed { background: #ffb300; } .st-skipped { background: #90a4ae; } .st-failed { background: #e53935; }
    .eb-stepbody { flex: 1; min-width: 0; }
    .eb-stephd { display: flex; align-items: center; gap: 8px; cursor: pointer; }
    .eb-stmod { font-family: ui-monospace, monospace; font-size: 11px; padding: 1px 6px; border-radius: 4px; background: color-mix(in srgb, var(--mat-sys-primary) 15%, transparent); }
    .eb-stname { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .eb-ststatus { font-size: 11px; text-transform: uppercase; font-weight: 600; }
    .st-txt-ok{color:#2e7d32} .st-txt-changed{color:#b57a00} .st-txt-skipped{color:#78909c} .st-txt-failed{color:#c62828}
    .eb-json { margin: 6px 0 0; padding: 8px; background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); border-radius: 6px; font-size: 11.5px; white-space: pre-wrap; overflow-wrap: anywhere; max-height: 320px; overflow: auto; }
    .eb-json.err { background: color-mix(in srgb, #e53935 12%, transparent); }
  `],
})
export class EventBrowserComponent {
  private http = inject(HttpClient);
  private auth = inject(AuthService);
  effects = [
    { key: '', label: 'All' },
    { key: 'changed', label: 'Changed' },
    { key: 'failed', label: 'Failed' },
    { key: 'unchanged', label: 'Unchanged' },
  ];
  runs = signal<RunRow[]>([]);
  selected = signal<RunRow | null>(null);
  detail = signal<RunDetail | null>(null);
  open = signal<Set<number>>(new Set());
  effect = signal('');
  q = '';
  retention = signal(0);
  retentionEdit = 0;
  busy = signal(false);
  msg = signal('');
  isAdmin = computed(() => this.auth.role() === 'admin');

  constructor() { this.loadRetention(); this.reload(); }

  reload(): void {
    this.busy.set(true);
    const params: string[] = ['limit=500'];
    if (this.effect()) params.push(`effect=${encodeURIComponent(this.effect())}`);
    if (this.q.trim()) params.push(`q=${encodeURIComponent(this.q.trim())}`);
    this.http.get<{ runs: RunRow[] }>(`${environment.apiUrl}/runbook-runs?${params.join('&')}`).subscribe({
      next: (r) => { this.runs.set(r.runs); this.busy.set(false); },
      error: () => this.busy.set(false),
    });
  }
  setEffect(k: string): void { this.effect.set(k); this.reload(); }
  select(r: RunRow): void {
    this.selected.set(r); this.detail.set(null); this.open.set(new Set());
    this.http.get<RunDetail>(`${environment.apiUrl}/runbook-runs/${r.id}`).subscribe((d) => this.detail.set(d));
  }
  toggle(i: number): void {
    const s = new Set(this.open()); s.has(i) ? s.delete(i) : s.add(i); this.open.set(s);
  }
  loadRetention(): void {
    this.http.get<{ run_retention_days: number }>(`${environment.apiUrl}/system/yolo-mode`).subscribe((s) => {
      this.retention.set(s.run_retention_days); this.retentionEdit = s.run_retention_days;
    });
  }
  saveRetention(): void {
    this.busy.set(true); this.msg.set('');
    this.http.put<{ run_retention_days: number }>(`${environment.apiUrl}/system/retention`, { run_retention_days: this.retentionEdit }).subscribe({
      next: (s) => { this.retention.set(s.run_retention_days); this.retentionEdit = s.run_retention_days; this.busy.set(false); this.msg.set('Retention saved.'); },
      error: () => { this.busy.set(false); this.msg.set('Save failed.'); },
    });
  }
  purge(olderThanDays: number): void {
    const label = olderThanDays > 0 ? `older than ${olderThanDays} days` : 'ALL history';
    if (!confirm(`Delete ${label}? This cannot be undone.`)) return;
    this.busy.set(true); this.msg.set('');
    const url = olderThanDays > 0 ? `${environment.apiUrl}/runbook-runs?older_than_days=${olderThanDays}` : `${environment.apiUrl}/runbook-runs`;
    this.http.delete<{ deleted: number }>(url).subscribe({
      next: (r) => { this.busy.set(false); this.msg.set(`Deleted ${r.deleted} events.`); this.selected.set(null); this.detail.set(null); this.reload(); },
      error: () => { this.busy.set(false); this.msg.set('Purge failed.'); },
    });
  }

  isAi(who: string | null): boolean { return !!who && who.startsWith('ai:'); }
  who(w: string | null): string { return w ? (w.startsWith('ai:') ? 'AI · ' + w.slice(3) : w) : 'system'; }
  when(iso: string): string { try { return new Date(iso).toLocaleString(); } catch { return iso; } }
  json(o: unknown): string { try { return JSON.stringify(o, null, 2); } catch { return String(o); } }
  recap(d: RunDetail): string {
    const s = d.result.steps || [];
    const c = s.filter((x) => x.status === 'changed').length;
    const f = s.filter((x) => x.status === 'failed').length;
    const k = s.filter((x) => x.status === 'skipped').length;
    const ok = s.length - c - f - k;
    return `ok=${ok} changed=${c} failed=${f} skipped=${k}`;
  }
}
