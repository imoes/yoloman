import { Component, OnInit, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import {
  BusinessServiceService, BusinessService, BusinessServiceInput, BsMember,
} from '../../core/services/business-service.service';
import { MonitoringService } from '../../core/services/monitoring.service';
import { HostGroupService } from '../../core/services/host-group.service';
import { OuService } from '../../core/services/ou.service';

/** BI / business service aggregation (gap #4): a logical service whose state is
 * rolled up from many underlying services across the fleet (AND/worst-of or
 * OR/redundancy). */
@Component({
  selector: 'app-business-services',
  standalone: true,
  imports: [FormsModule, MatButtonModule, MatIconModule],
  template: `
    <div class="bm-page">
      <div class="bm-head">
        <div>
          <h1>Business services</h1>
          <p class="bm-dim">Roll one state up from many underlying services across hosts. <strong>All</strong> = worst-of (every component must be OK — "Webshop = web AND db AND cache"). <strong>Any</strong> = best-of (OK if at least one is healthy — redundancy pools).</p>
        </div>
        <button mat-flat-button color="primary" (click)="startNew()"><mat-icon>add</mat-icon> New service</button>
      </div>

      @if (editing()) {
        <div class="bm-card bm-form">
          <div class="bm-row">
            <label>Name<input [(ngModel)]="draft.name" placeholder="Webshop" /></label>
            <label>Logic
              <select [(ngModel)]="draft.logic">
                <option value="all">All must be OK (AND / worst-of)</option>
                <option value="any">Any OK is enough (OR / redundancy)</option>
              </select>
            </label>
            <label class="bm-check"><input type="checkbox" [(ngModel)]="draft.enabled" /> Enabled</label>
          </div>
          <label class="bm-full">Description<input [(ngModel)]="draft.description" placeholder="optional" /></label>

          <div class="bm-members">
            <div class="bm-members-head"><strong>Members</strong> <span class="bm-dim">— each selector matches services on a scope, optionally filtered by name</span></div>
            @for (m of draft.members; track $index) {
              <div class="bm-member">
                <select [(ngModel)]="m.scope_type" (ngModelChange)="onScope(m)">
                  <option value="global">All hosts</option><option value="group">Host group</option>
                  <option value="ou">OU</option><option value="host">Single host</option>
                </select>
                @if (m.scope_type !== 'global') {
                  <select [ngModel]="targetId(m)" (ngModelChange)="setTarget(m, $event)">
                    <option value="" disabled>— target —</option>
                    @for (t of targets(m.scope_type); track t.id) { <option [value]="t.id">{{ t.name }}</option> }
                  </select>
                }
                <input [(ngModel)]="m.service_name" placeholder="service name filter (optional)" class="bm-mono" />
                <button mat-icon-button (click)="removeMember($index)" title="Remove"><mat-icon>close</mat-icon></button>
              </div>
            }
            <button mat-stroked-button (click)="addMember()"><mat-icon>add</mat-icon> Add member</button>
          </div>

          @if (formError()) { <p class="bm-err">{{ formError() }}</p> }
          <div class="bm-actions">
            <button mat-button (click)="editing.set(false)">Cancel</button>
            <button mat-flat-button color="primary" (click)="save()">{{ draft.id ? 'Save' : 'Create' }}</button>
          </div>
        </div>
      }

      @for (b of items(); track b.id) {
        <div class="bm-card">
          <div class="bm-bs-head">
            <div class="bm-bs-title">
              <span class="bm-dot bm-dot--{{ b.status }}"></span>
              <strong [class.bm-off]="!b.enabled">{{ b.name }}</strong>
              <span class="bm-status bm-status--{{ b.status }}">{{ b.status }}</span>
              <span class="bm-dim">{{ b.logic === 'all' ? 'AND' : 'OR' }} · {{ b.summary.member_count || 0 }} services</span>
              @if (b.description) { <span class="bm-dim">— {{ b.description }}</span> }
            </div>
            <div class="bm-bs-act">
              @if (b.summary.counts; as c) {
                @if (c['CRIT']) { <span class="bm-mini bm-mini--CRIT">{{ c['CRIT'] }} CRIT</span> }
                @if (c['WARN']) { <span class="bm-mini bm-mini--WARN">{{ c['WARN'] }} WARN</span> }
                @if (c['OK']) { <span class="bm-mini bm-mini--OK">{{ c['OK'] }} OK</span> }
              }
              <button mat-stroked-button (click)="evaluate(b)" [disabled]="busy() === b.id">{{ busy() === b.id ? '…' : 'Evaluate' }}</button>
              <button mat-button (click)="edit(b)">Edit</button>
              <button mat-button (click)="remove(b)">Delete</button>
            </div>
          </div>
        </div>
      } @empty { <p class="bm-dim">No business services yet.</p> }
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
    .bm-form label { display: flex; flex-direction: column; font-size: 12px; gap: 4px; flex: 1; min-width: 160px; }
    .bm-full { display: flex; flex-direction: column; font-size: 12px; gap: 4px; margin-bottom: 12px; }
    .bm-form input, .bm-form select { padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant);
      background: var(--mat-sys-surface); color: inherit; font: inherit; font-size: 13px; }
    .bm-check { flex-direction: row !important; align-items: center; flex: 0 0 auto; }
    .bm-members { border-top: 1px solid var(--mat-sys-outline-variant); padding-top: 12px; margin-bottom: 12px; }
    .bm-members-head { font-size: 13px; margin-bottom: 8px; }
    .bm-member { display: flex; gap: 8px; align-items: center; margin-bottom: 8px; }
    .bm-member select, .bm-member input { padding: 6px 9px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant);
      background: var(--mat-sys-surface); color: inherit; font: inherit; font-size: 13px; }
    .bm-member input { flex: 1; }
    .bm-actions { display: flex; justify-content: flex-end; gap: 8px; }
    .bm-mono { font-family: ui-monospace, monospace; }
    .bm-bs-head { display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; }
    .bm-bs-title { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
    .bm-bs-act { display: flex; align-items: center; gap: 6px; }
    .bm-off { text-decoration: line-through; opacity: 0.6; }
    .bm-dot { width: 11px; height: 11px; border-radius: 50%; display: inline-block; background: #9e9e9e; }
    .bm-dot--OK { background: var(--bm-green, #2e7d32); } .bm-dot--WARN { background: #f9a825; }
    .bm-dot--CRIT { background: var(--bm-red, #c62828); } .bm-dot--UNKNOWN { background: #9e9e9e; }
    .bm-status { font-size: 11px; padding: 1px 8px; border-radius: 10px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-status--OK { background: color-mix(in srgb, var(--bm-green, #2e7d32) 22%, transparent); }
    .bm-status--WARN { background: color-mix(in srgb, #f9a825 34%, transparent); }
    .bm-status--CRIT { background: color-mix(in srgb, var(--bm-red, #c62828) 24%, transparent); }
    .bm-err { color: var(--bm-red, #c62828); font-size: 13px; }
    .bm-mini { font-size: 11px; padding: 1px 7px; border-radius: 8px; }
    .bm-mini--CRIT { background: color-mix(in srgb, var(--bm-red, #c62828) 22%, transparent); }
    .bm-mini--WARN { background: color-mix(in srgb, #f9a825 32%, transparent); }
    .bm-mini--OK { background: color-mix(in srgb, var(--bm-green, #2e7d32) 20%, transparent); }
  `],
})
export class BusinessServicesComponent implements OnInit {
  private svc = inject(BusinessServiceService);
  private monitoring = inject(MonitoringService);
  private groups = inject(HostGroupService);
  private ous = inject(OuService);

  items = signal<BusinessService[]>([]);
  hosts = signal<{ id: string; name: string }[]>([]);
  groupList = signal<{ id: string; name: string }[]>([]);
  ouList = signal<{ id: string; name: string }[]>([]);
  editing = signal(false);
  busy = signal<string | null>(null);
  formError = signal('');
  draft: BusinessServiceInput & { id?: string } = this.blank();

  ngOnInit(): void {
    this.reload();
    this.monitoring.fleetHosts().subscribe((h) => this.hosts.set(h.map((x) => ({ id: x.id, name: x.name }))));
    this.groups.list().subscribe((g) => this.groupList.set(g.map((x) => ({ id: x.id, name: x.name }))));
    this.ous.list().subscribe((o) => this.ouList.set(o.map((x) => ({ id: x.id, name: x.name }))));
  }

  private blank(): BusinessServiceInput & { id?: string } {
    return { name: '', description: '', enabled: true, logic: 'all', members: [{ scope_type: 'global', service_name: '' }] };
  }
  private reload(): void { this.svc.list().subscribe((r) => this.items.set(r)); }

  targets(scope: string): { id: string; name: string }[] {
    return { host: this.hosts(), group: this.groupList(), ou: this.ouList(), global: [] }[scope] || [];
  }
  targetId(m: BsMember): string { return m.agent_id || m.host_group_id || m.ou_id || ''; }
  onScope(m: BsMember): void { m.agent_id = m.host_group_id = m.ou_id = null; }
  setTarget(m: BsMember, id: string): void {
    m.agent_id = m.scope_type === 'host' ? id : null;
    m.host_group_id = m.scope_type === 'group' ? id : null;
    m.ou_id = m.scope_type === 'ou' ? id : null;
  }
  addMember(): void { this.draft.members = [...this.draft.members, { scope_type: 'global', service_name: '' }]; }
  removeMember(i: number): void { this.draft.members = this.draft.members.filter((_, idx) => idx !== i); }

  startNew(): void { this.draft = this.blank(); this.formError.set(''); this.editing.set(true); }
  edit(b: BusinessService): void {
    this.draft = { id: b.id, name: b.name, description: b.description, enabled: b.enabled, logic: b.logic,
      members: b.members.map((m) => ({ ...m })) };
    this.formError.set(''); this.editing.set(true);
  }

  save(): void {
    const d = this.draft;
    if (!d.name.trim()) { this.formError.set('Name is required.'); return; }
    if (!d.members.length) { this.formError.set('Add at least one member.'); return; }
    for (const m of d.members) {
      if (m.scope_type !== 'global' && !this.targetId(m)) { this.formError.set('Every non-global member needs a target.'); return; }
    }
    const done = () => { this.editing.set(false); this.reload(); };
    const err = (e: { error?: { detail?: string } }) => this.formError.set(e?.error?.detail || 'save failed');
    if (d.id) this.svc.update(d.id, d).subscribe({ next: done, error: err });
    else this.svc.create(d).subscribe({ next: done, error: err });
  }
  evaluate(b: BusinessService): void {
    this.busy.set(b.id);
    this.svc.evaluate(b.id).subscribe({ next: () => { this.busy.set(null); this.reload(); }, error: () => this.busy.set(null) });
  }
  remove(b: BusinessService): void { this.svc.remove(b.id).subscribe(() => this.reload()); }
}
