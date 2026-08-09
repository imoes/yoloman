import { Component, OnInit, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import {
  ComplianceService, ComplianceRule, ComplianceRuleInput, ComplianceResult,
} from '../../core/services/compliance.service';
import { MonitoringService } from '../../core/services/monitoring.service';
import { HostGroupService } from '../../core/services/host-group.service';
import { OuService } from '../../core/services/ou.service';

/** Software compliance (gap #9): declare required/forbidden packages per
 * host/group/OU/fleet; hosts that drift out of policy are flagged and alerted. */
@Component({
  selector: 'app-compliance',
  standalone: true,
  imports: [FormsModule, MatButtonModule, MatIconModule],
  template: `
    <div class="bm-page">
      <div class="bm-head">
        <div>
          <h1>Software compliance</h1>
          <p class="bm-dim">Declare the packages that MUST and MUST NOT be installed on a scope. Hosts that drift out of policy are flagged and raise a notification. Version constraints: <code>openssl&gt;=3.0</code>, <code>log4j&lt;2.17</code>, <code>docker==24.0.7</code>.</p>
        </div>
        <button mat-flat-button color="primary" (click)="startNew()"><mat-icon>add</mat-icon> New rule</button>
      </div>

      @if (editing()) {
        <div class="bm-card bm-form">
          <div class="bm-row">
            <label>Name<input [(ngModel)]="draft.name" placeholder="baseline hygiene" /></label>
            <label>Severity
              <select [(ngModel)]="draft.severity"><option value="CRIT">CRIT</option><option value="WARN">WARN</option></select>
            </label>
            <label class="bm-check"><input type="checkbox" [(ngModel)]="draft.enabled" /> Enabled</label>
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
          </div>
          <div class="bm-row">
            <label>Required packages <span class="bm-dim">(one per line)</span>
              <textarea [(ngModel)]="requiredText" rows="4" class="bm-mono" placeholder="openssl&gt;=3.0&#10;ufw"></textarea>
            </label>
            <label>Forbidden packages <span class="bm-dim">(one per line)</span>
              <textarea [(ngModel)]="forbiddenText" rows="4" class="bm-mono" placeholder="telnet&#10;log4j&lt;2.17"></textarea>
            </label>
          </div>
          @if (formError()) { <p class="bm-err">{{ formError() }}</p> }
          <div class="bm-actions">
            <button mat-button (click)="editing.set(false)">Cancel</button>
            <button mat-flat-button color="primary" (click)="save()">{{ draft.id ? 'Save' : 'Create' }}</button>
          </div>
        </div>
      }

      @for (r of rules(); track r.id) {
        <div class="bm-card">
          <div class="bm-rule-head">
            <div>
              <strong [class.bm-off]="!r.enabled">{{ r.name }}</strong>
              <span class="bm-status bm-status--{{ r.severity }}">{{ r.severity }}</span>
              @if (!r.enabled) { <span class="bm-dim">· disabled</span> }
              <span class="bm-dim"> — {{ scopeLabel(r) }}</span>
              <div class="bm-specs">
                @if (r.required.length) { <span class="bm-dim">requires</span> @for (s of r.required; track s) { <code>{{ s }}</code> } }
                @if (r.forbidden.length) { <span class="bm-dim">forbids</span> @for (s of r.forbidden; track s) { <code class="bm-forbid">{{ s }}</code> } }
              </div>
            </div>
            <div class="bm-rule-act">
              <button mat-stroked-button (click)="evaluate(r)" [disabled]="busy() === r.id">{{ busy() === r.id ? '…' : 'Evaluate' }}</button>
              <button mat-button (click)="edit(r)">Edit</button>
              <button mat-button (click)="remove(r)">Delete</button>
            </div>
          </div>
          @if (results()[r.id]; as res) {
            <div class="bm-results">
              @for (h of res; track h.agent_id) {
                <div class="bm-hostrow">
                  <mat-icon class="{{ h.status === 'OK' ? 'bm-ok' : 'bm-err' }}">{{ h.status === 'OK' ? 'check_circle' : 'error' }}</mat-icon>
                  <span class="bm-hostname">{{ h.host_name }}</span>
                  @if (h.status === 'OK') { <span class="bm-dim">compliant</span> }
                  @else { <span class="bm-viol">{{ violText(h) }}</span> }
                </div>
              } @empty { <p class="bm-dim">No results yet — click Evaluate.</p> }
            </div>
          }
        </div>
      } @empty { <p class="bm-dim">No compliance rules yet.</p> }
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
    .bm-form label { display: flex; flex-direction: column; font-size: 12px; gap: 4px; flex: 1; min-width: 180px; }
    .bm-form input, .bm-form select, .bm-form textarea { padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant);
      background: var(--mat-sys-surface); color: inherit; font: inherit; font-size: 13px; }
    .bm-check { flex-direction: row !important; align-items: center; flex: 0 0 auto; }
    .bm-actions { display: flex; justify-content: flex-end; gap: 8px; }
    .bm-mono, code { font-family: ui-monospace, monospace; }
    code { font-size: 12px; padding: 1px 6px; border-radius: 5px; margin: 0 3px;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); }
    code.bm-forbid { background: color-mix(in srgb, var(--bm-red, #c62828) 16%, transparent); }
    .bm-rule-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; }
    .bm-rule-act { display: flex; align-items: center; gap: 6px; flex-shrink: 0; }
    .bm-specs { margin-top: 6px; font-size: 12px; }
    .bm-off { text-decoration: line-through; opacity: 0.6; }
    .bm-results { margin-top: 12px; border-top: 1px solid var(--mat-sys-outline-variant); padding-top: 10px; display: flex; flex-direction: column; gap: 6px; }
    .bm-hostrow { display: flex; align-items: center; gap: 8px; font-size: 13px; }
    .bm-hostrow mat-icon { font-size: 18px; width: 18px; height: 18px; }
    .bm-hostname { font-weight: 600; }
    .bm-viol { color: var(--bm-red, #c62828); font-size: 12px; }
    .bm-ok { color: var(--bm-green, #2e7d32); } .bm-err { color: var(--bm-red, #c62828); font-size: 13px; }
    .bm-status { font-size: 11px; padding: 1px 8px; border-radius: 10px; margin-left: 6px;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-status--CRIT { background: color-mix(in srgb, var(--bm-red, #c62828) 22%, transparent); }
    .bm-status--WARN { background: color-mix(in srgb, #f9a825 30%, transparent); }
  `],
})
export class ComplianceComponent implements OnInit {
  private svc = inject(ComplianceService);
  private monitoring = inject(MonitoringService);
  private groups = inject(HostGroupService);
  private ous = inject(OuService);

  rules = signal<ComplianceRule[]>([]);
  results = signal<Record<string, ComplianceResult[]>>({});
  hosts = signal<{ id: string; name: string }[]>([]);
  groupList = signal<{ id: string; name: string }[]>([]);
  ouList = signal<{ id: string; name: string }[]>([]);
  editing = signal(false);
  busy = signal<string | null>(null);
  formError = signal('');
  requiredText = '';
  forbiddenText = '';
  draft: ComplianceRuleInput & { id?: string } = this.blank();

  ngOnInit(): void {
    this.reload();
    this.monitoring.fleetHosts().subscribe((h) => this.hosts.set(h.map((x) => ({ id: x.id, name: x.name }))));
    this.groups.list().subscribe((g) => this.groupList.set(g.map((x) => ({ id: x.id, name: x.name }))));
    this.ous.list().subscribe((o) => this.ouList.set(o.map((x) => ({ id: x.id, name: x.name }))));
  }

  private blank(): ComplianceRuleInput & { id?: string } {
    return { name: '', enabled: true, scope_type: 'global', agent_id: null, host_group_id: null, ou_id: null,
      required: [], forbidden: [], severity: 'CRIT' };
  }
  private reload(): void {
    this.svc.list().subscribe((r) => { this.rules.set(r); r.forEach((x) => this.loadResults(x.id)); });
  }
  private loadResults(id: string): void {
    this.svc.results(id).subscribe((res) => this.results.update((m) => ({ ...m, [id]: res })));
  }

  targets(): { id: string; name: string }[] {
    return { host: this.hosts(), group: this.groupList(), ou: this.ouList(), global: [] }[this.draft.scope_type] || [];
  }
  targetId(): string { return this.draft.agent_id || this.draft.host_group_id || this.draft.ou_id || ''; }
  onScope(): void { this.draft.agent_id = this.draft.host_group_id = this.draft.ou_id = null; }
  setTarget(id: string): void {
    this.draft.agent_id = this.draft.scope_type === 'host' ? id : null;
    this.draft.host_group_id = this.draft.scope_type === 'group' ? id : null;
    this.draft.ou_id = this.draft.scope_type === 'ou' ? id : null;
  }
  scopeLabel(r: ComplianceRule): string {
    if (r.scope_type === 'global') return 'all hosts';
    const id = r.agent_id || r.host_group_id || r.ou_id || '';
    const all = [...this.hosts(), ...this.groupList(), ...this.ouList()];
    return `${r.scope_type}: ${all.find((t) => t.id === id)?.name ?? id.slice(0, 8)}`;
  }
  violText(h: ComplianceResult): string { return h.violations.map((v) => v.detail).join('; '); }

  startNew(): void { this.draft = this.blank(); this.requiredText = ''; this.forbiddenText = ''; this.formError.set(''); this.editing.set(true); }
  edit(r: ComplianceRule): void {
    this.draft = { id: r.id, name: r.name, enabled: r.enabled, scope_type: r.scope_type, agent_id: r.agent_id,
      host_group_id: r.host_group_id, ou_id: r.ou_id, required: r.required, forbidden: r.forbidden, severity: r.severity };
    this.requiredText = r.required.join('\n');
    this.forbiddenText = r.forbidden.join('\n');
    this.formError.set(''); this.editing.set(true);
  }

  private lines(s: string): string[] { return s.split('\n').map((x) => x.trim()).filter(Boolean); }

  save(): void {
    const d = this.draft;
    const body: ComplianceRuleInput = { ...d, required: this.lines(this.requiredText), forbidden: this.lines(this.forbiddenText) };
    if (!body.name.trim() || (body.scope_type !== 'global' && !this.targetId())) {
      this.formError.set('Name and a target (unless All hosts) are required.'); return;
    }
    if (!body.required.length && !body.forbidden.length) {
      this.formError.set('Add at least one required or forbidden package.'); return;
    }
    const done = () => { this.editing.set(false); this.reload(); };
    const err = (e: { error?: { detail?: string } }) => this.formError.set(e?.error?.detail || 'save failed');
    if (d.id) this.svc.update(d.id, body).subscribe({ next: done, error: err });
    else this.svc.create(body).subscribe({ next: done, error: err });
  }
  evaluate(r: ComplianceRule): void {
    this.busy.set(r.id);
    this.svc.evaluate(r.id).subscribe({
      next: () => { this.busy.set(null); this.loadResults(r.id); },
      error: () => this.busy.set(null),
    });
  }
  remove(r: ComplianceRule): void { this.svc.remove(r.id).subscribe(() => this.reload()); }
}
