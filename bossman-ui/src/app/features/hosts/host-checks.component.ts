import { Component, computed, effect, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatDialog } from '@angular/material/dialog';
import { RouterLink } from '@angular/router';
import { Agent } from '../../core/models/agent.model';
import { CheckCatalogEntry, CheckOption, DiscoveryProposal, EffectiveCheck } from '../../core/models/check.model';
import { ServiceState } from '../../core/models/monitoring.model';
import { CheckService } from '../../core/services/check.service';
import { MonitoringService } from '../../core/services/monitoring.service';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { serviceStateBadge } from '../../shared/status.util';
import {
  ScopeVarsDialogComponent,
  ScopeVarsDialogData,
} from '../../shared/components/scope-vars-dialog/scope-vars-dialog.component';

/**
 * Block G9-P2 — the host's Checks tab. Shows the checks that effectively
 * apply to this host (resolved GPO-style from OU/group/host assignments),
 * where each check's warn levels come from — and lets you add a check to
 * this host or override an inherited one's parameters right here (the "few
 * clicks, on the host page" model the user asked for). Group/OU-wide
 * assignment stays in OU/Policy; this tab is the host-centric view + host
 * overrides.
 */
@Component({
  selector: 'app-host-checks',
  standalone: true,
  imports: [FormsModule, MatButtonModule, MatIconModule, MatFormFieldModule, MatInputModule, MatSelectModule, RouterLink, HostStatusBadgeComponent],
  template: `
    <div class="bm-checks">
      @if (error()) { <div class="bm-error">{{ error() }}</div> }

      <!-- Toolbar: auto-discovery is THE primary path (essential-only, §10);
           the manual picker and variables are secondary/tertiary. -->
      <div class="bm-add">
        <button mat-flat-button color="primary" (click)="runDiscover()" [disabled]="discovering()">
          <mat-icon>travel_explore</mat-icon> {{ discovering() ? 'Discovering…' : 'Auto-discover checks' }}
        </button>
        <mat-form-field appearance="outline" class="bm-ff" subscriptSizing="dynamic">
          <mat-label>Add a check manually</mat-label>
          <mat-select [(ngModel)]="pickName" (ngModelChange)="onPick($event)">
            @for (c of addable(); track c.name) {
              <mat-option [value]="c.name">{{ c.name }}{{ c.short_description ? ' — ' + c.short_description : '' }}</mat-option>
            }
          </mat-select>
        </mat-form-field>
        <button mat-button (click)="editHostVars()">
          <mat-icon>data_object</mat-icon> Variables…
        </button>
      </div>

      @if (proposals() !== null) {
        <div class="bm-wizard">
          <div class="bm-form-title">Discovered checks for {{ agent().name }}</div>
          @if (proposals()!.length) {
            @for (p of proposals()!; track p.check_name) {
              <div class="bm-prop">
                <label class="bm-prop-head">
                  <input type="checkbox" [checked]="isSel(p.check_name)" (change)="toggleSel(p.check_name)" />
                  <span class="bm-mono">{{ p.check_name }}</span>
                  <span class="bm-dim">{{ p.short_description }}</span>
                  <span class="bm-count">{{ p.items.length }} item(s)</span>
                </label>
                <div class="bm-prop-items bm-dim">{{ itemsSummary(p) }}</div>
                @if (p.needs_params.length && isSel(p.check_name)) {
                  <div class="bm-creds">
                    <span class="bm-dim">Required parameters (e.g. credentials):</span>
                    @for (k of p.needs_params; track k) {
                      <mat-form-field appearance="outline" class="bm-ff-sm">
                        <mat-label>{{ k }} *</mat-label>
                        <input matInput [ngModel]="cred(p.check_name, k)" (ngModelChange)="setCred(p.check_name, k, $event)" />
                      </mat-form-field>
                    }
                  </div>
                }
                @if (isSel(p.check_name) && hasProvisioning(p.check_name)) {
                  <div class="bm-provision">
                    <span class="bm-dim">{{ provInfo()[p.check_name].title }} — provide admin credentials; a monitoring account is created and its credential stored (admin creds are not saved):</span>
                    <div class="bm-creds">
                      @for (a of provAdminParams(p.check_name); track a.name) {
                        <mat-form-field appearance="outline" class="bm-ff-sm">
                          <mat-label>{{ a.name }} *</mat-label>
                          <input matInput [type]="a.secret ? 'password' : 'text'"
                                 [ngModel]="adminCred(p.check_name, a.name)"
                                 (ngModelChange)="setAdminCred(p.check_name, a.name, $event)" />
                        </mat-form-field>
                      }
                      <button mat-stroked-button color="primary" (click)="provisionAndAssign(p.check_name)">
                        <mat-icon>key</mat-icon> Provision &amp; assign
                      </button>
                    </div>
                  </div>
                }
              </div>
            }
            <div class="bm-form-actions">
              <button mat-raised-button color="primary" (click)="applySelected()" [disabled]="!anySelected()">
                Assign selected to host
              </button>
              <button mat-button (click)="proposals.set(null)">Dismiss</button>
            </div>
          } @else {
            <p class="bm-dim">No checks discovered on this host. <button mat-button (click)="proposals.set(null)">Dismiss</button></p>
          }
        </div>
      }

      @if (pickName()) {
        <div class="bm-form">
          <div class="bm-form-title">Configure <b>{{ pickName() }}</b> for {{ agent().name }}</div>
          @for (o of pickOptions(); track o.key) {
            <mat-form-field appearance="outline" class="bm-ff">
              <mat-label>{{ o.key }}{{ o.spec.required ? ' *' : '' }}</mat-label>
              <input matInput [ngModel]="draft()[o.key]" (ngModelChange)="setDraft(o.key, $event)"
                     [placeholder]="o.spec.description || o.spec.type || ''" />
            </mat-form-field>
          }
          @if (!pickOptions().length) {
            <p class="bm-dim">This check has no parameters — assign it as-is.</p>
          }
          <div class="bm-form-actions">
            <button mat-raised-button color="primary" (click)="assign()">Assign to host</button>
            <button mat-button (click)="cancel()">Cancel</button>
          </div>
        </div>
      }

      <h3>Effective checks</h3>
      @if (checks().length) {
        <div class="bm-group">
        <table class="bm-table">
          <thead><tr><th>Check</th><th>From</th><th>Parameters</th><th></th></tr></thead>
          <tbody>
            @for (c of checks(); track c.check_name) {
              <tr [class.bm-orphan]="!c.in_library">
                <td class="bm-mono">{{ c.check_name }}<div class="bm-dim bm-sd">{{ c.short_description }}</div></td>
                <td><span class="bm-scope bm-scope-{{ c.source_scope }}">{{ scopeLabel(c) }}</span></td>
                <td class="bm-dim bm-params">{{ paramsSummary(c.parameters) }}</td>
                <td class="bm-actions">
                  @if (c.source_scope === 'host') {
                    <button mat-button (click)="remove(c)">Remove</button>
                  } @else {
                    <button mat-button (click)="override(c)">Override here</button>
                  }
                </td>
              </tr>
            }
          </tbody>
        </table>
        </div>
      } @else {
        <p class="bm-dim">No assigned checks on this host yet. Add one above, or assign a check to its OU/group in OU&nbsp;/&nbsp;Policy. Its live monitoring services are listed below.</p>
      }

      <!-- F-4: the monitoring services actually running on this host, so the
           tab reconciles the two notions of "check" (assigned Starlark checks
           above vs. threshold/built-in monitoring services here). -->
      <h3 class="bm-svc-h">Monitoring services <span class="bm-dim">({{ services().length }})</span></h3>
      <p class="bm-dim bm-svc-note">
        From threshold rules + the agent's built-in metrics — distinct from the assigned checks above.
        Edit thresholds in <a routerLink="/ou">OU&nbsp;/&nbsp;Policy</a>; full detail on the
        <a [routerLink]="['/hosts', agent().id]" [queryParams]="{ tab: 'services' }">Services</a> tab.
      </p>
      @if (services().length) {
        <div class="bm-group">
          <table class="bm-table">
            <thead><tr><th>Service</th><th>State</th><th class="bm-num">Value</th><th>Metric</th></tr></thead>
            <tbody>
              @for (s of services(); track s.id) {
                <tr>
                  <td>{{ s.name }}</td>
                  <td><app-status-badge [status]="serviceBadge(s)" [label]="s.state" /></td>
                  <td class="bm-num">{{ fmtValue(s) }}</td>
                  <td class="bm-dim bm-mono">{{ s.metric }}</td>
                </tr>
              }
            </tbody>
          </table>
        </div>
      } @else {
        <p class="bm-dim">No monitoring services reported yet.</p>
      }
    </div>
  `,
  styles: [
    `
      /* Grouped-inset layout (design-philosophy §9): comfortable max width,
         rounded hairline groups, quiet header rows. */
      .bm-checks { padding: 4px 2px; max-width: 960px; }
      .bm-svc-h { margin-top: 28px; }
      .bm-svc-note { font-size: 12px; margin: 2px 0 10px; }
      .bm-svc-note a { color: var(--mat-sys-primary); }
      .bm-add { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
      .bm-add, .bm-form { margin-bottom: 16px; }
      .bm-ff { width: 300px; max-width: 100%; }
      .bm-form { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 12px 14px; }
      .bm-form-title { margin-bottom: 8px; }
      .bm-form-actions { display: flex; gap: 8px; margin-top: 4px; }
      .bm-group { border: 1px solid var(--bm-hairline, var(--mat-sys-outline-variant)); border-radius: 10px; overflow: hidden; }
      .bm-group .bm-table td, .bm-group .bm-table th { padding-left: 14px; padding-right: 14px; }
      .bm-group .bm-table thead tr { background: color-mix(in srgb, var(--mat-sys-on-surface) 4%, transparent); }
      .bm-group .bm-table tbody tr:first-child td { border-top: none; }
      .bm-table { width: 100%; border-collapse: collapse; }
      .bm-table th { text-align: left; opacity: 0.6; font-weight: 500; padding: 8px 10px 8px 0; font-size: 12px; }
      .bm-table td { padding: 8px 10px 8px 0; border-top: 1px solid var(--bm-hairline, var(--mat-sys-outline-variant)); vertical-align: middle; }
      /* Humane numbers (§12): right-aligned, tabular digits, scannable. */
      .bm-num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; width: 110px; }
      .bm-mono { font-family: monospace; }
      .bm-sd { font-size: 11.5px; }
      .bm-dim { opacity: 0.6; }
      .bm-params { font-family: monospace; font-size: 12px; }
      .bm-scope { font-size: 11px; padding: 1px 8px; border-radius: 999px; }
      .bm-scope-host { background: color-mix(in srgb, var(--bm-green) 22%, transparent); }
      .bm-scope-group { background: color-mix(in srgb, var(--bm-gold, #caa300) 26%, transparent); }
      .bm-scope-ou { background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
      .bm-orphan { opacity: 0.55; }
      .bm-error { color: #d32f2f; margin-bottom: 10px; }
      h3 { margin: 14px 0 6px; font-size: 13px; opacity: 0.8; }
      .bm-wizard { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 12px 14px; margin-bottom: 14px; }
      .bm-prop { padding: 6px 0; border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-prop:first-of-type { border-top: none; }
      .bm-prop-head { display: flex; align-items: center; gap: 8px; cursor: pointer; }
      .bm-count { margin-left: auto; font-size: 12px; opacity: 0.7; }
      .bm-prop-items { font-size: 12px; margin: 2px 0 0 24px; }
      .bm-creds { margin: 6px 0 4px 24px; display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
      .bm-ff-sm { width: 200px; }
      .bm-provision { margin: 4px 0 4px 24px; padding: 6px 10px; border-left: 2px solid color-mix(in srgb, var(--bm-green) 50%, transparent); }
    `,
  ],
})
export class HostChecksComponent {
  private checkService = inject(CheckService);
  private monitoringService = inject(MonitoringService);
  private dialog = inject(MatDialog);
  agent = input.required<Agent>();
  /** F-4 bridge: the monitoring services actually active on this host (from
   * threshold check-rules + the agent's built-in metrics) — a different notion
   * of "check" than the assigned Starlark checks above, shown here so the tab
   * is the single "what's monitored on this host" view. */
  services = signal<ServiceState[]>([]);
  serviceBadge(s: ServiceState) { return serviceStateBadge(s.state); }

  /** Humane value formatting (design-philosophy §12): unit-aware, sensible
   * precision — never a raw float or raw seconds. */
  fmtValue(s: ServiceState): string {
    const v = s.value;
    if (v === null || v === undefined) return '—';
    const m = (s.metric || '').toLowerCase();
    if (m === 'uptime' || m.endsWith('_seconds') || s.name.toLowerCase() === 'uptime') {
      const d = Math.floor(v / 86400);
      const h = Math.floor((v % 86400) / 3600);
      if (d > 0) return `${d} d ${h} h`;
      const min = Math.floor((v % 3600) / 60);
      return h > 0 ? `${h} h ${min} min` : `${min} min`;
    }
    if (m.endsWith('_pct') || m.includes('percent')) return `${v.toFixed(1)} %`;
    if (Math.abs(v) >= 100) return v.toFixed(0);
    if (Math.abs(v) >= 10) return v.toFixed(1);
    return v.toFixed(2);
  }

  /** Host-scope runbook variables (strongest in the GPO merge). */
  editHostVars(): void {
    const a = this.agent();
    this.dialog.open<ScopeVarsDialogComponent, ScopeVarsDialogData, boolean>(
      ScopeVarsDialogComponent, { width: '560px', data: { scopeType: 'host', scopeId: a.id, scopeLabel: 'host ' + a.name } },
    );
  }

  checks = signal<EffectiveCheck[]>([]);
  catalog = signal<CheckCatalogEntry[]>([]);
  error = signal<string | null>(null);

  pickName = signal<string>('');
  draft = signal<Record<string, string>>({});

  // discovery wizard state
  proposals = signal<DiscoveryProposal[] | null>(null);
  discovering = signal(false);
  private selected = signal<Set<string>>(new Set());
  private creds = signal<Record<string, Record<string, string>>>({});
  // provisioning: per-check {available, title, admin_params} + collected admin creds
  provInfo = signal<Record<string, { available: boolean; title?: string; admin_params?: { name: string; secret: boolean; description: string }[] }>>({});
  private adminCreds = signal<Record<string, Record<string, string>>>({});

  /** Checks in the library not already effective on this host. */
  addable = computed(() => {
    const have = new Set(this.checks().map((c) => c.check_name));
    return this.catalog().filter((c) => !have.has(c.name));
  });

  pickOptions = computed<{ key: string; spec: CheckOption }[]>(() => {
    const c = this.catalog().find((x) => x.name === this.pickName());
    if (!c) return [];
    return Object.entries(c.options || {}).map(([key, spec]) => ({ key, spec }));
  });

  constructor() {
    // Reload whenever the bound agent changes (tab opened / host switched).
    effect(() => {
      const a = this.agent();
      if (a?.id) this.reload(a.id);
    });
  }

  private reload(agentId: string): void {
    this.checkService.effectiveHostChecks(agentId).subscribe({
      next: (r) => this.checks.set(r.checks),
      error: (e) => this.fail(e),
    });
    this.checkService.listChecks().subscribe({ next: (r) => this.catalog.set(r.checks) });
    this.monitoringService.agentServices(agentId).subscribe({ next: (s) => this.services.set(s ?? []), error: () => this.services.set([]) });
  }

  private fail(e: unknown): void {
    const d = (e as { error?: { detail?: string }; message?: string })?.error?.detail;
    this.error.set(d ?? (e as { message?: string })?.message ?? 'Request failed');
  }

  scopeLabel(c: EffectiveCheck): string {
    if (c.source_scope === 'host') return 'host';
    if (c.source_scope === 'group') return 'group';
    return 'OU';
  }

  paramsSummary(params: Record<string, unknown>): string {
    const keys = Object.keys(params || {});
    if (!keys.length) return '(defaults)';
    return keys.map((k) => `${k}=${JSON.stringify(params[k])}`).join(', ');
  }

  onPick(name: string): void {
    this.pickName.set(name);
    // Seed the draft with each option's default (as a string for the input).
    const c = this.catalog().find((x) => x.name === name);
    const d: Record<string, string> = {};
    for (const [k, spec] of Object.entries(c?.options || {})) {
      if (spec.default !== undefined && spec.default !== null) d[k] = String(spec.default);
    }
    this.draft.set(d);
  }

  setDraft(key: string, value: string): void {
    this.draft.update((d) => ({ ...d, [key]: value }));
  }

  cancel(): void {
    this.pickName.set('');
    this.draft.set({});
  }

  /** Coerce the string form values to typed params per the option's type. */
  private typedParams(name: string): Record<string, unknown> {
    const c = this.catalog().find((x) => x.name === name);
    const opts = c?.options || {};
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(this.draft())) {
      if (v === '' || v == null) continue;
      const t = (opts[k]?.type || '').toLowerCase();
      if (t === 'int' || t === 'integer') out[k] = parseInt(v, 10);
      else if (t === 'float' || t === 'number') out[k] = parseFloat(v);
      else if (t === 'bool' || t === 'boolean') out[k] = v === 'true' || v === '1' || v === 'yes';
      else out[k] = v;
    }
    return out;
  }

  assign(): void {
    const name = this.pickName();
    if (!name) return;
    this.error.set(null);
    this.checkService
      .createAssignment({ check_name: name, scope_type: 'host', agent_id: this.agent().id, parameters: this.typedParams(name) })
      .subscribe({
        next: () => { this.cancel(); this.reload(this.agent().id); },
        error: (e) => this.fail(e),
      });
  }

  /** Create a host-scoped override starting from the inherited params. */
  override(c: EffectiveCheck): void {
    this.pickName.set(c.check_name);
    const d: Record<string, string> = {};
    for (const [k, v] of Object.entries(c.parameters || {})) d[k] = String(v);
    this.draft.set(d);
  }

  remove(c: EffectiveCheck): void {
    this.checkService.deleteAssignment(c.assignment_id).subscribe({
      next: () => this.reload(this.agent().id),
      error: (e) => this.fail(e),
    });
  }

  // ── auto-discovery wizard ──────────────────────────────────────────────

  runDiscover(): void {
    this.error.set(null);
    this.discovering.set(true);
    this.proposals.set(null);
    this.selected.set(new Set());
    this.creds.set({});
    this.checkService.discover(this.agent().id).subscribe({
      next: (r) => {
        this.proposals.set(r.proposals);
        this.discovering.set(false);
        // Provisioning info is loaded lazily per check when it's selected (see
        // toggleSel) — fetching it for every proposal here was an N+1 flood
        // (hundreds of GET /checks/{name}/provisioning on a big discovery).
      },
      error: (e) => { this.fail(e); this.discovering.set(false); },
    });
  }

  hasProvisioning(check: string): boolean {
    return !!this.provInfo()[check]?.available;
  }

  provAdminParams(check: string): { name: string; secret: boolean; description: string }[] {
    return this.provInfo()[check]?.admin_params ?? [];
  }

  adminCred(check: string, key: string): string {
    return this.adminCreds()[check]?.[key] ?? '';
  }

  setAdminCred(check: string, key: string, value: string): void {
    this.adminCreds.update((c) => ({ ...c, [check]: { ...(c[check] || {}), [key]: value } }));
  }

  /** Run the check's provisioning recipe (create the monitoring account) then
   * assign it — the "MySQL needs a user" flow. */
  provisionAndAssign(check: string): void {
    this.error.set(null);
    this.checkService.provision(this.agent().id, check, this.adminCreds()[check] || {}).subscribe({
      next: () => { this.proposals.set(null); this.reload(this.agent().id); },
      error: (e) => this.fail(e),
    });
  }

  itemsSummary(p: DiscoveryProposal): string {
    if (p.error) return 'error: ' + p.error;
    const names = p.items.map((i) => i.item || '(single)').slice(0, 8);
    const more = p.items.length > 8 ? ` +${p.items.length - 8} more` : '';
    return names.join(', ') + more;
  }

  isSel(name: string): boolean {
    return this.selected().has(name);
  }

  anySelected(): boolean {
    return this.selected().size > 0;
  }

  toggleSel(name: string): void {
    this.selected.update((s) => {
      const n = new Set(s);
      if (n.has(name)) n.delete(name);
      else n.add(name);
      return n;
    });
    // Lazily fetch provisioning info the first time a check is selected — the
    // wizard only shows it for selected proposals.
    if (this.selected().has(name) && !(name in this.provInfo())) {
      this.checkService.provisioning(name).subscribe((info) =>
        this.provInfo.update((m) => ({ ...m, [name]: info })),
      );
    }
  }

  cred(check: string, key: string): string {
    return this.creds()[check]?.[key] ?? '';
  }

  setCred(check: string, key: string, value: string): void {
    this.creds.update((c) => ({ ...c, [check]: { ...(c[check] || {}), [key]: value } }));
  }

  applySelected(): void {
    const props = this.proposals() || [];
    const assign = props
      .filter((p) => this.isSel(p.check_name))
      .map((p) => ({ check_name: p.check_name, parameters: { ...(this.creds()[p.check_name] || {}) } }));
    if (!assign.length) return;
    this.checkService.applyDiscovery(this.agent().id, assign).subscribe({
      next: () => { this.proposals.set(null); this.reload(this.agent().id); },
      error: (e) => this.fail(e),
    });
  }
}
