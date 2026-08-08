import { Component, OnDestroy, OnInit, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { environment } from '../../../environments/environment';
import { RolloutService, Rollout, RolloutInput } from '../../core/services/rollout.service';
import { MonitoringService } from '../../core/services/monitoring.service';
import { HostGroupService } from '../../core/services/host-group.service';
import { OuService } from '../../core/services/ou.service';

/** Staged rollouts (gap #8): run a runbook across the fleet in waves
 * (canary → rings) with a health gate — patch nights done safely. */
@Component({
  selector: 'app-rollouts',
  standalone: true,
  imports: [FormsModule, MatButtonModule, MatIconModule],
  template: `
    <div class="bm-page">
      <div class="bm-head">
        <div>
          <h1>Rollouts</h1>
          <p class="bm-dim">Run a runbook across the fleet in waves — canary → rings — with a health gate that stops the rollout if a wave goes bad. For patch/reboot nights.</p>
        </div>
        <button mat-flat-button color="primary" (click)="startNew()"><mat-icon>add</mat-icon> New rollout</button>
      </div>

      @if (editing()) {
        <div class="bm-card bm-form">
          <div class="bm-row">
            <label>Name<input [(ngModel)]="draft.name" placeholder="July security patch" /></label>
            <label>Runbook
              <select [(ngModel)]="draft.runbook_name">
                <option value="" disabled>— pick —</option>
                @for (r of runbooks(); track r) { <option [value]="r">{{ r }}</option> }
              </select>
            </label>
          </div>
          <div class="bm-row">
            <label>Scope
              <select [(ngModel)]="draft.scope_type" (ngModelChange)="onScope()">
                <option value="global">All hosts</option><option value="group">Host group</option>
                <option value="ou">OU</option><option value="host">Single host</option>
              </select>
            </label>
            @if (draft.scope_type !== 'global') {
              <label>Target
                <select [ngModel]="targetId()" (ngModelChange)="setTarget($event)">
                  <option value="" disabled>— pick —</option>
                  @for (t of targets(); track t.id) { <option [value]="t.id">{{ t.name }}</option> }
                </select>
              </label>
            }
            @if (draft.scope_type === 'ou') {
              <label class="bm-check"><input type="checkbox" [(ngModel)]="draft.by_ou" /> Wave per OU (AD tree)</label>
            }
            @if (draft.by_ou && draft.scope_type === 'ou') {
              <label class="bm-check"><input type="checkbox" [(ngModel)]="draft.canary" /> Canary first host</label>
            } @else {
              <label>Waves (strategy)<input [(ngModel)]="strategyText" placeholder="1, 25%, rest" class="bm-mono" /></label>
            }
          </div>
          <div class="bm-row">
            <label>Health-gate wait (s)<input type="number" [(ngModel)]="draft.wait_seconds" /></label>
            <label>Max fail per wave (%)<input type="number" [(ngModel)]="maxFailPct" /></label>
            <label class="bm-check"><input type="checkbox" [(ngModel)]="draft.dry_run" /> Dry-run</label>
          </div>
          @if (formError()) { <p class="bm-err">{{ formError() }}</p> }
          <div class="bm-actions">
            <button mat-button (click)="editing.set(false)">Cancel</button>
            <button mat-flat-button color="primary" (click)="create()">Create</button>
          </div>
        </div>
      }

      @for (r of rollouts(); track r.id) {
        <div class="bm-card">
          <div class="bm-rollout-head">
            <div>
              <strong>{{ r.name }}</strong>{{ r.dry_run ? ' (dry-run)' : '' }}
              <span class="bm-dim">— {{ r.runbook_name }}, {{ r.waves.length }} wave(s)</span>
            </div>
            <div class="bm-rollout-act">
              <span class="bm-status bm-status--{{ r.status }}">{{ r.status }}</span>
              @if (r.status === 'pending') { <button mat-flat-button color="primary" (click)="start(r)">Start</button> }
              @if (r.status === 'running') { <button mat-stroked-button (click)="abort(r)">Abort</button> }
              <button mat-button (click)="remove(r)">Delete</button>
            </div>
          </div>
          <div class="bm-waves">
            @for (w of r.waves; track w.name; let i = $index) {
              <div class="bm-wave" [class.bm-wave--active]="r.status==='running' && r.current_wave===i" [class.bm-wave--done]="progressOf(r,i)">
                <div class="bm-wave-name">{{ w.name }} <span class="bm-dim">({{ w.agent_ids.length }})</span></div>
                @if (progressOf(r,i); as p) {
                  <div class="bm-wave-res">
                    <mat-icon class="{{ p.healthy === false ? 'bm-err' : 'bm-ok' }}">{{ p.healthy === false ? 'error' : 'check_circle' }}</mat-icon>
                    {{ p.ok }} ok, {{ p.failed }} failed<span class="bm-dim"> · {{ p.health }}</span>
                  </div>
                } @else if (r.status==='running' && r.current_wave===i) {
                  <div class="bm-wave-res bm-dim">running…</div>
                }
              </div>
            }
          </div>
        </div>
      } @empty { <p class="bm-dim">No rollouts yet.</p> }
    </div>
  `,
  styles: [`
    .bm-page { padding: 24px; max-width: 1100px; margin: 0 auto; }
    .bm-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; margin-bottom: 16px; }
    .bm-head h1 { margin: 0; }
    .bm-dim { opacity: 0.62; font-size: 13px; }
    .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 12px; padding: 14px 18px; margin-bottom: 14px;
      background: var(--mat-sys-surface-container-low, rgba(127,127,127,0.04)); }
    .bm-form .bm-row { display: flex; gap: 16px; margin-bottom: 12px; flex-wrap: wrap; }
    .bm-form label { display: flex; flex-direction: column; font-size: 12px; gap: 4px; flex: 1; min-width: 150px; }
    .bm-form input, .bm-form select { padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant);
      background: var(--mat-sys-surface); color: inherit; font: inherit; font-size: 13px; }
    .bm-check { flex-direction: row !important; align-items: center; }
    .bm-actions { display: flex; justify-content: flex-end; gap: 8px; }
    .bm-mono { font-family: ui-monospace, monospace; }
    .bm-rollout-head { display: flex; justify-content: space-between; align-items: center; gap: 12px; margin-bottom: 10px; }
    .bm-rollout-act { display: flex; align-items: center; gap: 8px; }
    .bm-waves { display: flex; gap: 10px; flex-wrap: wrap; }
    .bm-wave { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 8px 12px; min-width: 160px; }
    .bm-wave--active { border-color: var(--mat-sys-primary); box-shadow: 0 0 0 1px var(--mat-sys-primary) inset; }
    .bm-wave--done { opacity: 0.95; }
    .bm-wave-name { font-weight: 600; font-size: 13px; }
    .bm-wave-res { display: flex; align-items: center; gap: 4px; font-size: 12px; margin-top: 4px; }
    .bm-wave-res mat-icon { font-size: 16px; width: 16px; height: 16px; }
    .bm-ok { color: var(--bm-green, #2e7d32); } .bm-err { color: var(--bm-red, #c62828); }
    .bm-err { font-size: 13px; }
    .bm-status { font-size: 11px; padding: 2px 10px; border-radius: 10px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-status--running { background: color-mix(in srgb, var(--mat-sys-primary) 22%, transparent); }
    .bm-status--done { background: color-mix(in srgb, var(--bm-green, #2e7d32) 22%, transparent); }
    .bm-status--aborted, .bm-status--failed { background: color-mix(in srgb, var(--bm-red, #c62828) 22%, transparent); }
  `],
})
export class RolloutsComponent implements OnInit, OnDestroy {
  private svc = inject(RolloutService);
  private http = inject(HttpClient);
  private monitoring = inject(MonitoringService);
  private groups = inject(HostGroupService);
  private ous = inject(OuService);

  rollouts = signal<Rollout[]>([]);
  runbooks = signal<string[]>([]);
  hosts = signal<{ id: string; name: string }[]>([]);
  groupList = signal<{ id: string; name: string }[]>([]);
  ouList = signal<{ id: string; name: string }[]>([]);
  editing = signal(false);
  formError = signal('');
  strategyText = '1, 25%, rest';
  maxFailPct = 0;
  draft: RolloutInput = this.blank();
  private timer?: ReturnType<typeof setInterval>;

  ngOnInit(): void {
    this.reload();
    this.loadRefs();
    // Poll while any rollout is running so wave progress updates live.
    this.timer = setInterval(() => { if (this.rollouts().some((r) => r.status === 'running')) this.reload(); }, 4000);
  }
  ngOnDestroy(): void { if (this.timer) clearInterval(this.timer); }

  private blank(): RolloutInput {
    return { name: '', runbook_name: '', scope_type: 'global', agent_id: null, host_group_id: null, ou_id: null,
      strategy: [1, '25%', 'rest'], by_ou: false, canary: true, dry_run: true, wait_seconds: 30, max_fail_pct: 0 };
  }
  private reload(): void { this.svc.list().subscribe((r) => this.rollouts.set(r)); }
  private loadRefs(): void {
    this.monitoring.fleetHosts().subscribe((h) => this.hosts.set(h.map((x) => ({ id: x.id, name: x.name }))));
    this.groups.list().subscribe((g) => this.groupList.set(g.map((x) => ({ id: x.id, name: x.name }))));
    this.ous.list().subscribe((o) => this.ouList.set(o.map((x) => ({ id: x.id, name: x.name }))));
    this.http.get<{ runbooks: { name: string }[] }>(`${environment.apiUrl}/runbooks`)
      .subscribe((d) => this.runbooks.set((d.runbooks || []).map((x) => x.name).sort()));
  }

  targets(): { id: string; name: string }[] {
    return { host: this.hosts(), group: this.groupList(), ou: this.ouList(), global: [] }[this.draft.scope_type] || [];
  }
  targetId(): string { return this.draft.agent_id || this.draft.host_group_id || this.draft.ou_id || ''; }
  onScope(): void { this.draft.agent_id = this.draft.host_group_id = this.draft.ou_id = null; if (this.draft.scope_type !== 'ou') this.draft.by_ou = false; }
  setTarget(id: string): void {
    this.draft.agent_id = this.draft.scope_type === 'host' ? id : null;
    this.draft.host_group_id = this.draft.scope_type === 'group' ? id : null;
    this.draft.ou_id = this.draft.scope_type === 'ou' ? id : null;
  }
  progressOf(r: Rollout, i: number) { return r.progress[i]; }

  startNew(): void { this.draft = this.blank(); this.strategyText = '1, 25%, rest'; this.maxFailPct = 0; this.formError.set(''); this.editing.set(true); }

  create(): void {
    const strat = this.strategyText.split(',').map((s) => s.trim()).filter(Boolean)
      .map((s) => (/^\d+$/.test(s) ? Number(s) : s));
    const body: RolloutInput = { ...this.draft, strategy: strat, max_fail_pct: (this.maxFailPct || 0) / 100 };
    if (!body.name.trim() || !body.runbook_name || (body.scope_type !== 'global' && !this.targetId())) {
      this.formError.set('Name, runbook and a target (unless All hosts) are required.'); return;
    }
    this.svc.create(body).subscribe({
      next: () => { this.editing.set(false); this.reload(); },
      error: (e: { error?: { detail?: string } }) => this.formError.set(e?.error?.detail || 'create failed'),
    });
  }
  start(r: Rollout): void { this.svc.start(r.id).subscribe(() => this.reload()); }
  abort(r: Rollout): void { this.svc.abort(r.id).subscribe(() => this.reload()); }
  remove(r: Rollout): void { this.svc.remove(r.id).subscribe(() => this.reload()); }
}
