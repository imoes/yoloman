import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { CertService, CertTarget, CertTargetInput, CertSummary } from '../../core/services/cert.service';

/** Certificate / expiry inventory (gap #10): a fleet-wide board of TLS
 * certificates and other expiring things (licences, domains), sorted by
 * soonest expiry, with warn/crit thresholds and drift alerting. */
@Component({
  selector: 'app-certificates',
  standalone: true,
  imports: [DatePipe, FormsModule, MatButtonModule, MatIconModule],
  template: `
    <div class="bm-page">
      <div class="bm-head">
        <div>
          <h1>Certificate inventory</h1>
          <p class="bm-dim">One board for everything that expires — TLS certificates (probed from Bossman) plus manually-tracked licences and domain registrations — sorted by soonest expiry. Crossing the warn/crit days raises a notification.</p>
        </div>
        <button mat-flat-button color="primary" (click)="startNew()"><mat-icon>add</mat-icon> Add</button>
      </div>

      @if (summary(); as s) {
        <div class="bm-summary">
          <span class="bm-pill bm-pill--total">{{ s.total }} tracked</span>
          @for (st of statusOrder; track st) {
            @if (s.by_status[st]) { <span class="bm-pill bm-pill--{{ st }}">{{ s.by_status[st] }} {{ st }}</span> }
          }
        </div>
      }

      @if (editing()) {
        <div class="bm-card bm-form">
          <div class="bm-row">
            <label>Name<input [(ngModel)]="draft.name" placeholder="NetBox / VMware licence" /></label>
            <label>Type
              <select [(ngModel)]="draft.kind"><option value="tls">TLS endpoint</option><option value="manual">Manual expiry</option></select>
            </label>
            <label class="bm-check"><input type="checkbox" [(ngModel)]="draft.enabled" /> Enabled</label>
          </div>
          <div class="bm-row">
            @if (draft.kind === 'tls') {
              <label>Endpoint<input [(ngModel)]="draft.endpoint" placeholder="host:port  or  https://host/" class="bm-mono" /></label>
            } @else {
              <label>Expiry date<input type="date" [(ngModel)]="manualDate" /></label>
            }
            <label>Warn (days)<input type="number" [(ngModel)]="draft.warn_days" /></label>
            <label>Crit (days)<input type="number" [(ngModel)]="draft.crit_days" /></label>
          </div>
          @if (formError()) { <p class="bm-err">{{ formError() }}</p> }
          <div class="bm-actions">
            <button mat-button (click)="editing.set(false)">Cancel</button>
            <button mat-flat-button color="primary" (click)="save()">{{ draft.id ? 'Save' : 'Add' }}</button>
          </div>
        </div>
      }

      <div class="bm-table-wrap">
        <table class="bm-table">
          <thead><tr>
            <th>Status</th><th>Name</th><th>Subject / endpoint</th><th>Issuer</th><th>Expires</th><th>Days</th><th></th>
          </tr></thead>
          <tbody>
            @for (t of targets(); track t.id) {
              <tr>
                <td><span class="bm-status bm-status--{{ t.status }}">{{ t.status }}</span></td>
                <td><strong [class.bm-off]="!t.enabled">{{ t.name }}</strong> <span class="bm-dim">{{ t.kind === 'manual' ? '(manual)' : '' }}</span></td>
                <td class="bm-mono bm-sub">{{ t.subject || t.endpoint || '—' }}@if (t.last_error) {<span class="bm-err"> — {{ t.last_error }}</span>}</td>
                <td class="bm-dim">{{ t.issuer || '—' }}</td>
                <td>{{ t.not_after ? (t.not_after | date:'yyyy-MM-dd') : '—' }}</td>
                <td [class.bm-err]="t.days_left !== null && t.days_left <= t.crit_days" [class.bm-warn]="t.days_left !== null && t.days_left > t.crit_days && t.days_left <= t.warn_days">
                  {{ t.days_left === null ? '—' : t.days_left }}
                </td>
                <td class="bm-rowact">
                  <button mat-icon-button title="Check now" (click)="check(t)" [disabled]="busy() === t.id"><mat-icon>{{ busy() === t.id ? 'hourglass_empty' : 'refresh' }}</mat-icon></button>
                  <button mat-icon-button title="Edit" (click)="edit(t)"><mat-icon>edit</mat-icon></button>
                  <button mat-icon-button title="Delete" (click)="remove(t)"><mat-icon>delete</mat-icon></button>
                </td>
              </tr>
            } @empty { <tr><td colspan="7" class="bm-dim">No certificates tracked yet.</td></tr> }
          </tbody>
        </table>
      </div>
    </div>
  `,
  styles: [`
    .bm-page { padding: 24px; max-width: 1200px; margin: 0 auto; }
    .bm-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; margin-bottom: 12px; }
    .bm-head h1 { margin: 0; }
    .bm-dim { opacity: 0.62; font-size: 13px; }
    .bm-summary { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 16px; }
    .bm-pill { font-size: 12px; padding: 3px 12px; border-radius: 12px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-pill--total { font-weight: 600; }
    .bm-pill--critical, .bm-pill--expired, .bm-pill--error { background: color-mix(in srgb, var(--bm-red, #c62828) 22%, transparent); }
    .bm-pill--warning { background: color-mix(in srgb, #f9a825 32%, transparent); }
    .bm-pill--ok { background: color-mix(in srgb, var(--bm-green, #2e7d32) 22%, transparent); }
    .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 12px; padding: 14px 18px; margin-bottom: 16px;
      background: var(--mat-sys-surface-container-low, rgba(127,127,127,0.04)); }
    .bm-form .bm-row { display: flex; gap: 16px; margin-bottom: 12px; flex-wrap: wrap; }
    .bm-form label { display: flex; flex-direction: column; font-size: 12px; gap: 4px; flex: 1; min-width: 140px; }
    .bm-form input, .bm-form select { padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant);
      background: var(--mat-sys-surface); color: inherit; font: inherit; font-size: 13px; }
    .bm-check { flex-direction: row !important; align-items: center; flex: 0 0 auto; }
    .bm-actions { display: flex; justify-content: flex-end; gap: 8px; }
    .bm-mono { font-family: ui-monospace, monospace; }
    .bm-table-wrap { overflow-x: auto; }
    .bm-table { width: 100%; border-collapse: collapse; font-size: 13px; }
    .bm-table th { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); font-size: 11px; text-transform: uppercase; opacity: 0.6; }
    .bm-table td { padding: 8px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); vertical-align: middle; }
    .bm-sub { max-width: 320px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bm-off { text-decoration: line-through; opacity: 0.6; }
    .bm-rowact { white-space: nowrap; text-align: right; }
    .bm-err { color: var(--bm-red, #c62828); }
    .bm-warn { color: #f9a825; }
    .bm-status { font-size: 11px; padding: 2px 9px; border-radius: 10px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-status--critical, .bm-status--expired, .bm-status--error { background: color-mix(in srgb, var(--bm-red, #c62828) 24%, transparent); }
    .bm-status--warning { background: color-mix(in srgb, #f9a825 34%, transparent); }
    .bm-status--ok { background: color-mix(in srgb, var(--bm-green, #2e7d32) 24%, transparent); }
  `],
})
export class CertificatesComponent implements OnInit {
  private svc = inject(CertService);
  statusOrder: CertTarget['status'][] = ['expired', 'critical', 'error', 'warning', 'unknown', 'ok'];
  targets = signal<CertTarget[]>([]);
  summary = signal<CertSummary | null>(null);
  editing = signal(false);
  busy = signal<string | null>(null);
  formError = signal('');
  manualDate = '';
  draft: CertTargetInput & { id?: string } = this.blank();

  ngOnInit(): void { this.reload(); }

  private blank(): CertTargetInput & { id?: string } {
    return { name: '', enabled: true, kind: 'tls', endpoint: '', warn_days: 30, crit_days: 7, not_after: null };
  }
  private reload(): void {
    this.svc.list().subscribe((t) => this.targets.set(t));
    this.svc.summary().subscribe((s) => this.summary.set(s));
  }

  startNew(): void { this.draft = this.blank(); this.manualDate = ''; this.formError.set(''); this.editing.set(true); }
  edit(t: CertTarget): void {
    this.draft = { id: t.id, name: t.name, enabled: t.enabled, kind: t.kind, endpoint: t.endpoint,
      warn_days: t.warn_days, crit_days: t.crit_days, not_after: t.not_after };
    this.manualDate = t.not_after ? t.not_after.slice(0, 10) : '';
    this.formError.set(''); this.editing.set(true);
  }

  save(): void {
    const d = this.draft;
    const body: CertTargetInput = { ...d };
    if (d.kind === 'manual') {
      if (!this.manualDate) { this.formError.set('Pick an expiry date.'); return; }
      body.not_after = new Date(this.manualDate + 'T00:00:00Z').toISOString();
    } else if (!body.endpoint.trim()) {
      this.formError.set('Enter a host:port or URL.'); return;
    }
    if (!body.name.trim()) { this.formError.set('Name is required.'); return; }
    const done = () => { this.editing.set(false); this.reload(); };
    const err = (e: { error?: { detail?: string } }) => this.formError.set(e?.error?.detail || 'save failed');
    if (d.id) this.svc.update(d.id, body).subscribe({ next: done, error: err });
    else this.svc.create(body).subscribe({ next: done, error: err });
  }
  check(t: CertTarget): void {
    this.busy.set(t.id);
    this.svc.check(t.id).subscribe({ next: () => { this.busy.set(null); this.reload(); }, error: () => this.busy.set(null) });
  }
  remove(t: CertTarget): void { this.svc.remove(t.id).subscribe(() => this.reload()); }
}
