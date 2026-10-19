import { Component, OnInit, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { environment } from '../../../environments/environment';
import { SchedulerService, ScheduledJob, ScheduledJobInput } from '../../core/services/scheduler.service';
import { MonitoringService } from '../../core/services/monitoring.service';
import { HostGroupService } from '../../core/services/host-group.service';
import { OuService } from '../../core/services/ou.service';
import { StatusPillComponent } from '../../shared/status-pill/status-pill.component';

/** Scheduler (gap #7): recurring runbook runs on a cron schedule, scoped to a
 * host / group / OU — patch nights, weekly hygiene, scheduled maintenance. */
@Component({
  selector: 'app-scheduler',
  standalone: true,
  imports: [StatusPillComponent, DatePipe, FormsModule, MatButtonModule, MatIconModule],
  template: `
    <div class="bm-page">
      <div class="bm-head">
        <div>
          <h1>Scheduler</h1>
          <p class="bm-dim">Run a runbook on a schedule — patch nights, weekly hygiene, maintenance. Cron: <code>min hour dom mon dow</code> (e.g. <code>0 3 * * 0</code> = Sundays 03:00).</p>
        </div>
        <button mat-flat-button color="primary" (click)="startNew()"><mat-icon>add</mat-icon> New scheduled job</button>
      </div>

      @if (editing()) {
        <div class="bm-card bm-form">
          <div class="bm-row">
            <label>Name<input [(ngModel)]="draft.name" placeholder="weekly redis restart" /></label>
            <label>Cron<input [(ngModel)]="draft.cron" placeholder="0 3 * * 0" class="bm-mono" /></label>
          </div>
          <div class="bm-row">
            <label>Runbook
              <select [(ngModel)]="draft.runbook_name">
                <option value="" disabled>— pick a runbook —</option>
                @for (r of runbooks(); track r) { <option [value]="r">{{ r }}</option> }
              </select>
            </label>
            <label>Scope
              <select [(ngModel)]="draft.scope_type" (ngModelChange)="onScope()">
                <option value="host">Host</option><option value="group">Host group</option><option value="ou">OU</option>
              </select>
            </label>
            <label>Target
              <select [ngModel]="targetId()" (ngModelChange)="setTarget($event)">
                <option value="" disabled>— pick —</option>
                @for (t of targets(); track t.id) { <option [value]="t.id">{{ t.name }}</option> }
              </select>
            </label>
          </div>
          <div class="bm-row">
            <label class="bm-check"><input type="checkbox" [(ngModel)]="draft.dry_run" /> Dry-run (preview only, no changes)</label>
          </div>
          @if (formError()) { <p class="bm-err">{{ formError() }}</p> }
          <div class="bm-actions">
            <button mat-button (click)="editing.set(false)">Cancel</button>
            <button mat-flat-button color="primary" (click)="save()">{{ draft.id ? 'Save' : 'Create' }}</button>
          </div>
        </div>
      }

      @if (runError()) { <p class="bm-err" role="alert">{{ runError() }}</p> }
      <div class="bm-card">
        <table class="bm-table">
          <thead><tr><th></th><th>Name</th><th>Cron</th><th>Runbook</th><th>Scope</th><th>Last run</th><th>Status</th><th></th></tr></thead>
          <tbody>
            @for (j of jobs(); track j.id) {
              <tr>
                <td><input type="checkbox" [checked]="j.enabled" (change)="toggle(j)" title="enabled" /></td>
                <td>{{ j.name }}{{ j.dry_run ? ' (dry-run)' : '' }}</td>
                <td class="bm-mono">{{ j.cron }}</td>
                <td class="bm-mono">{{ j.runbook_name }}</td>
                <td>{{ j.scope_type }}: {{ scopeLabel(j) }}</td>
                <td>{{ j.last_run_at ? (j.last_run_at | date: 'short') : '—' }}</td>
                <td><bm-status-pill [status]="j.last_status || 'never'" [label]="j.last_status || 'never run'" />
                  @if (j.last_detail) { <span class="bm-dim bm-detail">{{ j.last_detail }}</span> }
                </td>
                <td class="bm-act">
                  <span class="bm-why" [attr.title]="running() === j.id ? 'Running… the result appears under Status' : null"><button mat-stroked-button (click)="runNow(j)" [disabled]="running() === j.id">{{ running() === j.id ? '…' : 'Run now' }}</button></span>
                  <button mat-button (click)="edit(j)">Edit</button>
                  <button mat-button (click)="remove(j)">Delete</button>
                </td>
              </tr>
            } @empty {
              <tr><td colspan="8" class="bm-dim">No scheduled jobs yet.</td></tr>
            }
          </tbody>
        </table>
      </div>
    </div>
  `,
  styles: [`
    .bm-page { padding: 24px; max-width: 1200px; margin: 0 auto; }
    .bm-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; margin-bottom: 16px; }
    .bm-head h1 { margin: 0; }
    .bm-dim { opacity: 0.62; font-size: 13px; margin: 4px 0 0; }
    .bm-detail { display: block; font-size: 11px; }
    .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 12px; padding: 16px 20px; margin-bottom: 16px;
      background: var(--mat-sys-surface-container-low, rgba(127,127,127,0.04)); }
    .bm-form .bm-row { display: flex; gap: 16px; margin-bottom: 12px; flex-wrap: wrap; }
    .bm-form label { display: flex; flex-direction: column; font-size: 12px; gap: 4px; flex: 1; min-width: 160px; }
    .bm-form input, .bm-form select { padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant);
      background: var(--mat-sys-surface); color: inherit; font: inherit; font-size: 13px; }
    .bm-check { flex-direction: row !important; align-items: center; }
    .bm-actions { display: flex; justify-content: flex-end; gap: 8px; }
    .bm-table { width: 100%; border-collapse: collapse; font-size: var(--bm-font-table); }
    .bm-table th { text-align: left; font-size: 12px; opacity: 0.6; padding: var(--bm-cell-py) var(--bm-cell-px); }
    .bm-table td { padding: var(--bm-cell-py) var(--bm-cell-px); border-top: 1px solid var(--mat-sys-outline-variant); vertical-align: middle; }
    .bm-mono { font-family: ui-monospace, monospace; font-size: 12px; }
    .bm-act { display: flex; gap: 4px; }
    .bm-err { color: var(--bm-red, #c62828); font-size: 13px; }
  `],
})
export class SchedulerComponent implements OnInit {
  private svc = inject(SchedulerService);
  private http = inject(HttpClient);
  private monitoring = inject(MonitoringService);
  private groups = inject(HostGroupService);
  private ous = inject(OuService);

  jobs = signal<ScheduledJob[]>([]);
  runbooks = signal<string[]>([]);
  hosts = signal<{ id: string; name: string }[]>([]);
  groupList = signal<{ id: string; name: string }[]>([]);
  ouList = signal<{ id: string; name: string }[]>([]);
  editing = signal(false);
  runError = signal('');
  running = signal<string | null>(null);
  formError = signal('');

  draft: ScheduledJobInput & { id?: string } = this.blank();

  // Methods, not computed(): `draft` is a plain ngModel object, and a computed() over it is evaluated once and
  // cached — targetId() stayed '' forever, so Create always answered "a target is required" and no job could be
  // created from this screen; targets() kept listing hosts after the scope was switched to group/OU.
  targets(): { id: string; name: string }[] {
    return ({ host: this.hosts(), group: this.groupList(), ou: this.ouList() }[this.draft.scope_type] || []);
  }
  targetId(): string { return this.draft.agent_id || this.draft.host_group_id || this.draft.ou_id || ''; }
  onScope(): void { this.draft.agent_id = this.draft.host_group_id = this.draft.ou_id = null; }

  ngOnInit(): void {
    this.reload();
    this.loadRefs();
  }

  private blank(): ScheduledJobInput & { id?: string } {
    return { name: '', enabled: true, cron: '0 3 * * 0', runbook_name: '', scope_type: 'host',
      agent_id: null, host_group_id: null, ou_id: null, variables: {}, dry_run: false };
  }

  private reload(): void { this.svc.list().subscribe((j) => this.jobs.set(j)); }

  private loadRefs(): void {
    this.monitoring.fleetHosts().subscribe((h) => this.hosts.set(h.map((x) => ({ id: x.id, name: x.name }))));
    this.groups.list().subscribe((g) => this.groupList.set(g.map((x) => ({ id: x.id, name: x.name }))));
    this.ous.list().subscribe((o) => this.ouList.set(o.map((x) => ({ id: x.id, name: x.name }))));
    // Runbook names via HttpClient (the auth interceptor adds the token).
    this.http.get<{ runbooks: { name: string }[] }>(`${environment.apiUrl}/runbooks`)
      .subscribe((d) => this.runbooks.set((d.runbooks || []).map((x) => x.name).sort()));
  }

  scopeLabel(j: ScheduledJob): string {
    const id = j.agent_id || j.host_group_id || j.ou_id;
    const all = [...this.hosts(), ...this.groupList(), ...this.ouList()];
    return all.find((t) => t.id === id)?.name ?? (id ? id.slice(0, 8) : '—');
  }

  setTarget(id: string): void {
    this.draft.agent_id = this.draft.scope_type === 'host' ? id : null;
    this.draft.host_group_id = this.draft.scope_type === 'group' ? id : null;
    this.draft.ou_id = this.draft.scope_type === 'ou' ? id : null;
  }

  startNew(): void { this.draft = this.blank(); this.formError.set(''); this.editing.set(true); }
  edit(j: ScheduledJob): void {
    this.draft = { id: j.id, name: j.name, cron: j.cron, runbook_name: j.runbook_name, scope_type: j.scope_type,
      agent_id: j.agent_id ?? null, host_group_id: j.host_group_id ?? null, ou_id: j.ou_id ?? null,
      variables: j.variables || {}, dry_run: j.dry_run, enabled: j.enabled } as ScheduledJobInput & { id?: string };
    this.formError.set(''); this.editing.set(true);
  }

  save(): void {
    const d = this.draft;
    const missing = [!d.name.trim() && 'a name', !d.cron.trim() && 'a cron expression', !d.runbook_name && 'a runbook',
      !this.targetId() && 'a target'].filter(Boolean);
    if (missing.length) { this.formError.set(`Still needed: ${missing.join(', ')}.`); return; }
    const body: ScheduledJobInput = { ...d, enabled: d.enabled ?? true };
    const done = () => { this.editing.set(false); this.reload(); };
    const err = (e: { error?: { detail?: string } }) => this.formError.set(e?.error?.detail || 'save failed');
    if (d.id) this.svc.update(d.id, body).subscribe({ next: done, error: err });
    else this.svc.create(body).subscribe({ next: done, error: err });
  }

  toggle(j: ScheduledJob): void {
    this.svc.update(j.id, { ...j, enabled: !j.enabled } as ScheduledJobInput).subscribe(() => this.reload());
  }
  runNow(j: ScheduledJob): void {
    this.running.set(j.id);
    this.runError.set('');
    // A refused run is said, not swallowed: the row's status would otherwise just not change, with no reason.
    this.svc.runNow(j.id).subscribe({
      next: () => { this.running.set(null); this.reload(); },
      error: (e: { error?: { detail?: string } }) => { this.running.set(null); this.runError.set(`${j.name}: ${e?.error?.detail || 'run failed'}`); },
    });
  }
  remove(j: ScheduledJob): void { this.svc.remove(j.id).subscribe(() => this.reload()); }
}
