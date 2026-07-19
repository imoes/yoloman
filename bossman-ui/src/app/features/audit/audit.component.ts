import { Component, OnInit, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { AuditService, AuditEntry, AuditStats } from '../../core/services/audit.service';

/** Audit log (gap #13): a searchable who-did-what-when trail. Rows come from the
 * audit middleware (every authenticated mutation) plus explicit login events. */
@Component({
  selector: 'app-audit',
  standalone: true,
  imports: [DatePipe, FormsModule, MatButtonModule, MatIconModule],
  template: `
    <div class="bm-page">
      <div class="bm-head">
        <div>
          <h1>Audit log</h1>
          <p class="bm-dim">Who did what, when. Every authenticated change (create/update/delete) and every login is recorded. Admin-only.</p>
        </div>
      </div>

      @if (stats(); as s) {
        <div class="bm-summary">
          <span class="bm-pill bm-pill--total">{{ s.total }} entries</span>
          @if (s.failed) { <span class="bm-pill bm-pill--failed">{{ s.failed }} failed</span> }
          @for (c of categories(s); track c[0]) { <span class="bm-pill">{{ c[1] }} {{ c[0] }}</span> }
        </div>
      }

      <div class="bm-filters">
        <input placeholder="search action / path / target" [(ngModel)]="fq" (keyup.enter)="reload()" class="bm-mono" />
        <select [(ngModel)]="fCategory" (ngModelChange)="reload()">
          <option value="">all categories</option>
          @for (c of catOptions; track c) { <option [value]="c">{{ c }}</option> }
        </select>
        <select [(ngModel)]="fStatus" (ngModelChange)="reload()">
          <option value="">any status</option><option value="ok">ok</option><option value="failed">failed</option>
        </select>
        <input placeholder="actor" [(ngModel)]="fActor" (keyup.enter)="reload()" />
        <button mat-stroked-button (click)="reload()"><mat-icon>search</mat-icon> Search</button>
      </div>

      <div class="bm-table-wrap">
        <table class="bm-table">
          <thead><tr><th>When</th><th>Actor</th><th>Category</th><th>Action</th><th>Target</th><th>Status</th><th>IP</th></tr></thead>
          <tbody>
            @for (e of entries(); track e.id) {
              <tr [class.bm-failed]="e.status === 'failed'">
                <td class="bm-nowrap">{{ e.at | date:'yyyy-MM-dd HH:mm:ss' }}</td>
                <td><strong>{{ e.actor }}</strong>@if (e.actor_kind === 'api_token') { <span class="bm-dim"> (token)</span> }</td>
                <td><span class="bm-cat bm-cat--{{ e.category }}">{{ e.category }}</span></td>
                <td class="bm-mono bm-action">{{ e.action }}</td>
                <td class="bm-mono bm-dim bm-target">{{ e.target || '—' }}</td>
                <td><span class="bm-st bm-st--{{ e.status }}">{{ e.status }}</span>@if (e.status_code) { <span class="bm-dim"> {{ e.status_code }}</span> }</td>
                <td class="bm-dim bm-nowrap">{{ e.source_ip || '—' }}</td>
              </tr>
            } @empty { <tr><td colspan="7" class="bm-dim">No audit entries match.</td></tr> }
          </tbody>
        </table>
      </div>
    </div>
  `,
  styles: [`
    .bm-page { padding: 24px; max-width: 1250px; margin: 0 auto; }
    .bm-head h1 { margin: 0; }
    .bm-dim { opacity: 0.62; }
    .bm-summary { display: flex; gap: 8px; flex-wrap: wrap; margin: 14px 0; }
    .bm-pill { font-size: 12px; padding: 3px 12px; border-radius: 12px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-pill--total { font-weight: 600; }
    .bm-pill--failed { background: color-mix(in srgb, var(--bm-red, #c62828) 22%, transparent); }
    .bm-filters { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 14px; align-items: center; }
    .bm-filters input, .bm-filters select { padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant);
      background: var(--mat-sys-surface); color: inherit; font: inherit; font-size: 13px; }
    .bm-filters input { min-width: 160px; }
    .bm-mono { font-family: ui-monospace, monospace; }
    .bm-table-wrap { overflow-x: auto; }
    .bm-table { width: 100%; border-collapse: collapse; font-size: 13px; }
    .bm-table th { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); font-size: 11px; text-transform: uppercase; opacity: 0.6; }
    .bm-table td { padding: 7px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); vertical-align: top; }
    .bm-nowrap { white-space: nowrap; }
    .bm-action { max-width: 380px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bm-target { max-width: 200px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bm-failed { background: color-mix(in srgb, var(--bm-red, #c62828) 7%, transparent); }
    .bm-cat { font-size: 11px; padding: 1px 8px; border-radius: 9px; background: color-mix(in srgb, var(--mat-sys-primary) 15%, transparent); }
    .bm-cat--auth { background: color-mix(in srgb, #6a1b9a 26%, transparent); }
    .bm-cat--access { background: color-mix(in srgb, #ad1457 26%, transparent); }
    .bm-cat--execution { background: color-mix(in srgb, #1565c0 26%, transparent); }
    .bm-cat--config, .bm-cat--policy { background: color-mix(in srgb, #00838f 26%, transparent); }
    .bm-st { font-size: 11px; padding: 1px 8px; border-radius: 9px; background: color-mix(in srgb, var(--bm-green, #2e7d32) 22%, transparent); }
    .bm-st--failed { background: color-mix(in srgb, var(--bm-red, #c62828) 26%, transparent); }
  `],
})
export class AuditComponent implements OnInit {
  private svc = inject(AuditService);
  entries = signal<AuditEntry[]>([]);
  stats = signal<AuditStats | null>(null);
  catOptions = ['auth', 'access', 'config', 'policy', 'execution', 'monitoring', 'other'];
  fq = '';
  fCategory = '';
  fStatus = '';
  fActor = '';

  ngOnInit(): void { this.reload(); this.svc.stats().subscribe((s) => this.stats.set(s)); }

  reload(): void {
    this.svc.list({ q: this.fq, category: this.fCategory, status: this.fStatus, actor: this.fActor, limit: 200 })
      .subscribe((e) => this.entries.set(e));
  }
  categories(s: AuditStats): [string, number][] {
    return Object.entries(s.by_category).sort((a, b) => b[1] - a[1]);
  }
}
