import { Component, computed, effect, inject, input, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressBarModule } from '@angular/material/progress-bar';
import { MatDialog, MatDialogModule } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { RouterLink } from '@angular/router';
import { Agent } from '../../core/models/agent.model';
import { CheckCatalogEntry, CheckOption, DiscoveryProposal, EffectiveCheck } from '../../core/models/check.model';
import { ServiceState } from '../../core/models/monitoring.model';
import { CheckService } from '../../core/services/check.service';
import { MonitoringService } from '../../core/services/monitoring.service';
import { AgentService } from '../../core/services/agent.service';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { ServiceChecksComponent } from './management/service-checks/service-checks.component';
import { serviceStateBadge } from '../../shared/status.util';
import { formatMetricValue, serviceMetricSpec } from '../../shared/format.util';
import { ThresholdDialogComponent } from '../../shared/components/threshold-dialog/threshold-dialog.component';

/** One row of the persisted discovery result (Checkmk's autochecks). */
interface DiscoRow {
  check_name: string; item: string | null; state: string;
  first_seen?: string; last_seen?: string; parameters?: Record<string, unknown>;
}

/**
 * Block G9-P2 — the host's Checks tab: everything this host is measured by, and what came
 * back. Four different things live here and the sections say which is which, because "check"
 * used to name all four at once:
 *
 *   Check              a definition in the library      (browsed in Library ▸ Checks)
 *   Assigned check     a RULE: it applies to this host  (Service checks + Effective checks)
 *   Discovered service a FACT: discovery found it       (Discovered services)
 *   Service state      a MEASUREMENT: what it reported  (Service states)
 *
 * The SERVICE CHECKS section is the folded-in Management ▸ Service checks snap-in. That split
 * was worse than redundancy: this tab explicitly filtered the "Service checks" category out
 * (with a comment calling the snap-in the single source of truth), so a tab named "Checks"
 * hid a whole class of the host's own checks and nothing on it said so. See
 * docs/logik-audit.md, area 1. Group/OU-wide assignment still belongs to OU / Policy — that
 * is a different scope, not a second place for the same scope.
 */
@Component({
  selector: 'app-host-checks',
  standalone: true,
  imports: [DatePipe, FormsModule, MatButtonModule, MatIconModule, MatProgressBarModule, MatFormFieldModule, MatInputModule, RouterLink, HostStatusBadgeComponent, ServiceChecksComponent, MatDialogModule],
  template: `
    <div class="bm-checks">
      @if (error()) { <div class="bm-error">{{ error() }}</div> }

      <!-- Toolbar: auto-discovery is the host-centric path (it proposes from what the host
           actually has). Adding an endpoint check by hand is the Service checks section
           below — on this same tab, so both ways of getting a check onto this host are in
           one place. -->
      <div class="bm-add">
        <button mat-flat-button color="primary" (click)="runDiscover()" [disabled]="discovering()">
          <mat-icon>travel_explore</mat-icon> {{ discovering() ? 'Discovering…' : 'Auto-discover checks' }}
        </button>
        <button mat-stroked-button (click)="recheckNow()" [disabled]="rechecking()"
                title="Run this host's checks now instead of waiting for the next poll">
          <mat-icon>refresh</mat-icon> {{ rechecking() ? 'Rechecking…' : 'Recheck now' }}
        </button>
      </div>

      @if (discovering()) {
        <div class="bm-disco-progress">
          <mat-progress-bar mode="determinate" [value]="discoverPercent()"></mat-progress-bar>
          <span class="bm-dim">Discovering… {{ discoverPercent() }}%</span>
        </div>
      }

      @if (proposals() !== null) {
        <div class="bm-wizard">
          <div class="bm-form-title">Discovered checks for {{ agent().name }}</div>
          @if (proposals()!.length) {
            @for (p of proposals()!; track p.check_name) {
              <div class="bm-prop">
                <div class="bm-prop-head">
                  <input type="checkbox" [checked]="isSel(p.check_name)" (change)="toggleSel(p.check_name)" />
                  <button type="button" class="bm-prop-expand" (click)="toggleExpand(p.check_name)"
                          [attr.aria-label]="isExpanded(p.check_name) ? 'Collapse' : 'Read description'">
                    <mat-icon>{{ isExpanded(p.check_name) ? 'expand_more' : 'chevron_right' }}</mat-icon>
                  </button>
                  <span class="bm-mono">{{ p.check_name }}</span>
                  <span class="bm-dim">{{ p.short_description }}</span>
                  <span class="bm-count">{{ p.items.length }} item(s)</span>
                </div>
                @if (isExpanded(p.check_name)) {
                  <div class="bm-prop-desc">
                    @if (description(p.check_name)) {
                      <pre>{{ description(p.check_name) }}</pre>
                    } @else {
                      <span class="bm-dim">Loading description…</span>
                    }
                  </div>
                }
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

      <!-- Reached only via "Override here" on an inherited (OU/group) check — set
           host-scoped parameters. Adding a NEW check is either Auto-discover above or the
           Service checks section below. -->
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

      <!-- What discovery KNOWS about this host, in every state the model can hold.
           Without this a service that disappears from the host also disappears from
           the view — the state space would be incomplete and nobody would learn that
           something is missing (Checkmk calls this state "vanished"). -->
      @if (disco(); as d) {
        <h3>Discovered services
          <span class="bm-dim bm-disco-sub">what discovery found on the host — a fact, not a rule</span>
        </h3>
        <div class="bm-disco-tabs">
          @for (b of discoBuckets(); track b.key) {
            <button type="button" class="bm-disco-tab" [class.sel]="discoFilter() === b.key"
                    [class.warn]="b.key === 'vanished' && b.count > 0"
                    (click)="discoFilter.set(b.key)" [title]="b.hint">
              {{ b.label }} <b>{{ b.count }}</b>
            </button>
          }
        </div>
        @if (discoRows().length) {
          <div class="bm-group">
            <table class="bm-table">
              <thead><tr><th>Service</th><th>Item</th><th>State</th><th>Last seen</th><th></th></tr></thead>
              <tbody>
                @for (s of discoRows(); track s.check_name + '/' + (s.item || '')) {
                  <tr [class.bm-disco-gone]="s.state === 'vanished'">
                    <td class="bm-mono">{{ s.check_name }}</td>
                    <td class="bm-dim">{{ s.item || '—' }}</td>
                    <td>
                      <span class="bm-disco-state" [class.gone]="s.state === 'vanished'"
                            [class.ign]="s.state === 'ignored'" [title]="discoStateHint(s.state)">
                        {{ discoStateLabel(s.state) }}
                      </span>
                    </td>
                    <td class="bm-dim">{{ s.last_seen ? (s.last_seen | date: 'short') : '—' }}</td>
                    <td class="bm-svc-actions">
                      @if (s.state === 'vanished') {
                        <button mat-button (click)="discoDecide('remove', s)" [disabled]="discoBusy()"
                                title="It is gone — stop tracking it (the row is dropped)">Remove</button>
                        <button mat-button (click)="discoDecide('ignore', s)" [disabled]="discoBusy()"
                                title="Keep the entry but never offer it again">Ignore</button>
                      } @else if (s.state === 'undecided') {
                        <button mat-button (click)="discoDecide('accept', s)" [disabled]="discoBusy()"
                                title="Monitor it from now on">Monitor</button>
                        <button mat-button (click)="discoDecide('ignore', s)" [disabled]="discoBusy()"
                                title="Remembered — later runs stop offering it">Ignore</button>
                      } @else if (s.state === 'monitored') {
                        <button mat-button (click)="discoDecide('remove', s)" [disabled]="discoBusy()"
                                title="Stop monitoring it; discovery offers it again next run">Stop</button>
                      } @else {
                        <button mat-button (click)="discoDecide('accept', s)" [disabled]="discoBusy()"
                                title="Undo the ignore and monitor it">Monitor</button>
                      }
                    </td>
                  </tr>
                }
              </tbody>
            </table>
          </div>
        } @else {
          <p class="bm-dim">Nothing in this state.</p>
        }
      }

      <!-- The active endpoint checks (HTTP/TCP/DNS/certificate). They used to live only in
           Management > Service checks while THIS tab filtered them out, so the tab called
           "Checks" hid a whole class of the host's checks and nothing said so. Now they are
           here, where every other check of this host is, and the one place that can add or
           edit them is here too. -->
      <h3>Service checks</h3>
      <p class="bm-dim bm-what">
        <b>Assigned check</b> (a rule): an endpoint this host actively probes. Configure and add
        them here — they are listed separately from the checks below only because they are
        authored differently, not because they live elsewhere.
      </p>
      <app-service-checks [agentId]="agent().id" />

      <h3>Effective checks</h3>
      <p class="bm-dim bm-what">
        <b>Assigned check</b> (a rule): a check from the library that applies to this host,
        inherited from its OU/group or set here. The service checks above are not repeated.
      </p>
      @if (effectiveChecks().length) {
        <div class="bm-group">
        <table class="bm-table">
          <thead><tr><th>Check</th><th>From</th><th>Parameters</th><th></th></tr></thead>
          <tbody>
            @for (c of effectiveChecks(); track c.check_name) {
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
        <p class="bm-dim">No library checks assigned to this host yet. Run <b>Auto-discover checks</b> above, add a <b>service check</b> in the section above, or assign a check to its OU/group in OU&nbsp;/&nbsp;Policy. Its live monitoring services are listed below.</p>
      }

      <!-- F-4: the monitoring services actually running on this host, so the
           tab reconciles the two notions of "check" (assigned Starlark checks
           above vs. threshold/built-in monitoring services here). -->
      <h3 class="bm-svc-h">Service states <span class="bm-dim">({{ services().length }})</span></h3>
      <p class="bm-dim bm-what">
        <b>Service state</b> (a measurement): what a check most recently reported. A rule above
        says what to measure; a row here says what came back.
      </p>
      <p class="bm-dim bm-svc-note">
        From threshold rules + the agent's built-in metrics — distinct from the assigned checks above.
        <b>Click a threshold to change it for this host</b> — the same editor the
        <a [routerLink]="['/hosts', agent().id]" [queryParams]="{ tab: 'services' }">Services</a> tab
        opens, reached from here so a value you are looking at is a value you can edit. Setting it
        for MANY hosts is a different scope, not a different editor:
        <a routerLink="/ou">OU&nbsp;/&nbsp;Policy</a>.
      </p>
      @if (services().length) {
        <div class="bm-group">
          <table class="bm-table">
            <thead><tr><th>Service</th><th>State</th><th class="bm-num">Value</th><th>Threshold</th><th>Metric</th><th></th></tr></thead>
            <tbody>
              @for (s of services(); track s.id) {
                <tr>
                  <td>{{ s.name }}</td>
                  <td><app-status-badge [status]="serviceBadge(s)" [label]="s.state" /></td>
                  <td class="bm-num">{{ fmtValue(s) }}</td>
                  <!-- WHY is this row WARN/CRIT? A state without its threshold is an
                       assertion without a reason. The API already ships it
                       (ServiceOut.warn/crit_threshold + comparison). -->
                  <!-- The threshold is editable HERE, not only two screens away. It is the same
                       ThresholdDialogComponent the Services tab opens and the same createCheckRule
                       behind it: two entry points, ONE editor. Two editors for one value would be
                       the actual mistake — this is a second door, not a second room. -->
                  <td class="bm-thr">
                    <button class="bm-thr-btn" [title]="thresholdHint(s) || 'Set a warn/crit threshold for this service on this host'"
                            (click)="editThreshold(s)">
                      @if (s.warn_threshold != null || s.crit_threshold != null) {
                        <span class="bm-mono">{{ thresholdText(s) }}</span>
                      } @else {
                        <span class="bm-thr-none">set…</span>
                      }
                    </button>
                  </td>
                  <td class="bm-dim bm-mono">{{ s.metric }}</td>
                  <td class="bm-svc-actions">
                    <button mat-icon-button class="bm-del" [disabled]="deleting() === s.id"
                            title="Delete this service (for orphaned/stale rows; recreated next poll if a producer still materialises it)"
                            (click)="removeService(s)">
                      <mat-icon>delete_outline</mat-icon>
                    </button>
                  </td>
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
      /* Discovery states: all four buckets always visible, and "vanished" has to
         LOOK different — an unnoticed missing service is the failure this section
         exists to prevent. */
      .bm-thr { font-size: 12px; white-space: nowrap; opacity: 0.85; }
      /* The threshold reads as text until hovered, then as the control it is: a table full of
         buttons is noise, but a value you can change must not look inert either. */
      .bm-thr-btn { font: inherit; color: inherit; background: none; border: 1px solid transparent;
        border-radius: 5px; padding: 2px 6px; cursor: pointer; text-align: left; }
      .bm-thr-btn:hover, .bm-thr-btn:focus-visible { border-color: var(--mat-sys-outline-variant);
        background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
      .bm-thr-none { opacity: 0.5; font-style: italic; }
      .bm-disco-sub { font-weight: 400; font-size: 12px; margin-left: 8px; }
      .bm-disco-tabs { display: flex; gap: 6px; flex-wrap: wrap; margin: 6px 0 10px; }
      .bm-disco-tab { font: inherit; font-size: 12.5px; padding: 4px 10px; border-radius: 20px;
        cursor: pointer; border: 1px solid var(--mat-sys-outline-variant); background: transparent;
        color: var(--mat-sys-on-surface); }
      .bm-disco-tab.sel { border-color: var(--mat-sys-primary);
        background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent); }
      .bm-disco-tab.warn { border-color: #e5534b; color: #e5534b; }
      .bm-disco-tab.warn.sel { background: color-mix(in srgb, #e5534b 18%, transparent); color: #ff8b84; }
      .bm-disco-state { font-size: 11.5px; padding: 1px 8px; border-radius: 10px;
        border: 1px solid var(--mat-sys-outline-variant); }
      .bm-disco-state.gone { color: #ff8b84; border-color: #e5534b;
        background: color-mix(in srgb, #e5534b 14%, transparent); }
      .bm-disco-state.ign { opacity: 0.6; }
      .bm-disco-gone td.bm-mono, .bm-disco-gone .bm-mono { text-decoration: line-through; opacity: 0.8; }

      /* Grouped-inset layout (design-philosophy §9): comfortable max width,
         rounded hairline groups, quiet header rows. */
      .bm-checks { padding: 4px 2px; max-width: 960px; }
      .bm-svc-h { margin-top: 28px; }
      .bm-what { margin: 2px 0 8px; font-size: 12.5px; max-width: 860px; }
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
      .bm-prop-head { display: flex; align-items: center; gap: 8px; }
      .bm-prop-expand { background: none; border: none; color: inherit; cursor: pointer; padding: 2px; display: inline-flex; opacity: 0.7; border-radius: 4px; }
      .bm-prop-expand:hover { opacity: 1; background: var(--bm-hover, rgba(255,255,255,0.06)); }
      .bm-prop-expand mat-icon { font-size: 20px; width: 20px; height: 20px; }
      .bm-prop-desc { margin: 4px 0 8px 46px; padding: 10px 12px; border-left: 2px solid var(--bm-hairline, var(--mat-sys-outline-variant)); background: color-mix(in srgb, var(--mat-sys-on-surface) 3%, transparent); border-radius: 0 6px 6px 0; }
      .bm-prop-desc pre { margin: 0; white-space: pre-wrap; font-family: inherit; font-size: 12.5px; line-height: 1.5; opacity: 0.9; }
      .bm-count { margin-left: auto; font-size: 12px; opacity: 0.7; }
      .bm-prop-items { font-size: 12px; margin: 2px 0 0 46px; }
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
  private agentService = inject(AgentService);
  agent = input.required<Agent>();
  /** F-4 bridge: the monitoring services actually active on this host (from
   * threshold check-rules + the agent's built-in metrics) — a different notion
   * of "check" than the assigned Starlark checks above, shown here so the tab
   * is the single "what's monitored on this host" view. */
  services = signal<ServiceState[]>([]);
  serviceBadge(s: ServiceState) { return serviceStateBadge(s.state); }

  /** Humane value formatting (design-philosophy §12) — shared formatter. */
  fmtValue(s: ServiceState): string { return formatMetricValue(s.value, s.metric, s.name); }

  // Expand a discovery proposal to read its full description before selecting.
  private expanded = signal<Set<string>>(new Set());
  private descriptions = signal<Record<string, string>>({});
  isExpanded(name: string): boolean { return this.expanded().has(name); }
  description(name: string): string { return this.descriptions()[name] ?? ''; }
  toggleExpand(name: string): void {
    const s = new Set(this.expanded());
    if (s.has(name)) { s.delete(name); this.expanded.set(s); return; }
    s.add(name);
    this.expanded.set(s);
    this.loadDescription(name);
  }

  /** Lazy-load a check's full description (once). */
  private loadDescription(name: string): void {
    if (this.descriptions()[name] !== undefined) return;
    this.descriptions.update((m) => ({ ...m, [name]: '' })); // mark loading
    this.checkService.getCheck(name).subscribe({
      next: (c) => {
        const desc = (c as { metadata?: { description?: string } })?.metadata?.description || 'No description available.';
        this.descriptions.update((m) => ({ ...m, [name]: desc }));
      },
      error: () => this.descriptions.update((m) => ({ ...m, [name]: 'Could not load description.' })),
    });
  }

  checks = signal<EffectiveCheck[]>([]);
  catalog = signal<CheckCatalogEntry[]>([]);
  error = signal<string | null>(null);

  pickName = signal<string>('');
  draft = signal<Record<string, string>>({});

  // discovery wizard state
  proposals = signal<DiscoveryProposal[] | null>(null);
  discovering = signal(false);
  // 0–100, driven by the discovery job's progress poll (Checkmk-style ~1400-check run).
  discoverPercent = signal(0);
  rechecking = signal(false);
  deleting = signal<string | null>(null);
  private selected = signal<Set<string>>(new Set());
  private creds = signal<Record<string, Record<string, string>>>({});
  // provisioning: per-check {available, title, admin_params} + collected admin creds
  provInfo = signal<Record<string, { available: boolean; title?: string; admin_params?: { name: string; secret: boolean; description: string }[] }>>({});
  private adminCreds = signal<Record<string, Record<string, string>>>({});

  /** Effective checks minus the active "Service checks" (HTTP/TCP/DNS/…): those have their
   * own section ON THIS TAB, which is where they are added and edited, so repeating them in
   * this table would show the same row twice on one screen. The difference from before is
   * that the other section is now here rather than in a Management snap-in — the rows are
   * not hidden from the tab any more, only sorted into the section that can act on them.
   * Checks not in the library keep showing (orphan view). */
  effectiveChecks = computed(() => {
    const cat = new Map(this.catalog().map((c) => [c.name, c.category]));
    return this.checks().filter((c) => cat.get(c.check_name) !== 'Service checks');
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

  /** Force an immediate poll (runs the host's assigned checks + rebuilds its
   * services), then refresh the tab — instead of waiting for the next poll. */
  recheckNow(): void {
    const id = this.agent()?.id;
    if (!id || this.rechecking()) return;
    this.rechecking.set(true);
    this.agentService.pollNow(id).subscribe({
      next: () => { this.rechecking.set(false); this.reload(id); },
      error: (e) => { this.rechecking.set(false); this.fail(e); },
    });
  }

  /** Delete an orphaned/stale monitoring service row. Only removes the small
   * services-table row (never the compressed time-series). If a producer still
   * materialises it, it reappears next poll — the confirm text says so. */
  removeService(s: ServiceState): void {
    if (this.deleting()) return;
    if (!confirm(`Delete monitoring service "${s.name}"?\n\nRemoves the service row only (its history ages out on its own). If a check assignment, rule, or agent builtin still produces it, it will reappear on the next poll — unassign/remove that first.`)) return;
    this.deleting.set(s.id);
    this.monitoringService.deleteService(s.id).subscribe({
      next: () => { this.deleting.set(null); this.services.update((list) => list.filter((x) => x.id !== s.id)); },
      error: (e) => { this.deleting.set(null); this.fail(e); },
    });
  }

  /** Just the service states — a threshold change does not alter the assigned checks or the
   * catalog, so reloading all four lists would be noise. */
  private refreshServices(): void {
    this.monitoringService.agentServices(this.agent().id).subscribe({
      next: (v) => this.services.set(v ?? []), error: () => this.services.set([]),
    });
  }

  private reload(agentId: string): void {
    this.checkService.effectiveHostChecks(agentId).subscribe({
      next: (r) => this.checks.set(r.checks),
      error: (e) => this.fail(e),
    });
    this.checkService.listChecks().subscribe({ next: (r) => this.catalog.set(r.checks) });
    this.monitoringService.agentServices(agentId).subscribe({ next: (s) => this.services.set(s ?? []), error: () => this.services.set([]) });
    this.checkService.discoveredServices(agentId).subscribe({
      next: (d) => this.disco.set(d), error: () => this.disco.set(null),
    });
  }

  // ---- discovered services: every state the model holds, none of them silent ----
  disco = signal<{ counts: Record<string, number>; services: DiscoRow[] } | null>(null);
  discoFilter = signal<string>('vanished');
  discoBusy = signal(false);

  /** The four lifecycle states, always all four — a bucket with 0 still shows, so
   *  "no vanished services" is a statement rather than an absence. */
  discoBuckets(): { key: string; label: string; count: number; hint: string }[] {
    const c = this.disco()?.counts || {};
    return [
      { key: 'vanished', label: 'Vanished', count: c['vanished'] || 0,
        hint: 'Was found before, this run did not find it — decide: remove or ignore' },
      { key: 'undecided', label: 'New', count: c['undecided'] || 0,
        hint: 'Discovery found it, nobody decided yet' },
      { key: 'monitored', label: 'Monitored', count: c['monitored'] || 0,
        hint: 'Found and being monitored' },
      { key: 'ignored', label: 'Ignored', count: c['ignored'] || 0,
        hint: 'Decided against — later runs stop offering it' },
    ];
  }
  discoRows(): DiscoRow[] {
    return (this.disco()?.services || []).filter((s) => s.state === this.discoFilter());
  }
  discoStateLabel(state: string): string {
    return state === 'undecided' ? 'new' : state;
  }
  discoStateHint(state: string): string {
    return this.discoBuckets().find((b) => b.key === state)?.hint || state;
  }
  /** accept | ignore | remove — the verbs the API already implements. */
  discoDecide(verb: 'accept' | 'ignore' | 'remove', s: DiscoRow): void {
    this.discoBusy.set(true);
    const spec = { check_name: s.check_name, item: s.item || undefined };
    this.checkService.decideDiscovery(this.agent().id, { [verb]: [spec] }).subscribe({
      next: () => { this.discoBusy.set(false); this.reload(this.agent().id); },
      error: (e) => { this.discoBusy.set(false); this.fail(e); },
    });
  }

  private fail(e: unknown): void {
    const d = (e as { error?: { detail?: string }; message?: string })?.error?.detail;
    this.error.set(d ?? (e as { message?: string })?.message ?? 'Request failed');
  }

  /** The rule this row is graded against, e.g. ">= 80 / >= 90". Answering "why is
   *  this WARN?" needs the comparison too — "80" alone does not say which side is
   *  bad. */
  thresholdText(s: ServiceState): string {
    const op = this.comparisonText(s.comparison);
    const parts: string[] = [];
    if (s.warn_threshold != null) parts.push(`${op}${s.warn_threshold}`);
    if (s.crit_threshold != null) parts.push(`${op}${s.crit_threshold}`);
    return parts.join(' / ');
  }
  /** Where the numbers come from + what they mean — the provenance the assignment
   *  table shows in its "From" column, spelled out here for the measurement. */
  thresholdHint(s: ServiceState): string {
    if (s.warn_threshold == null && s.crit_threshold == null) {
      return 'No threshold rule: this check reports its own state, so there is no value to grade. '
           + 'Add a rule in OU / Policy to grade it.';
    }
    const w = s.warn_threshold != null ? `warn ${this.comparisonText(s.comparison)}${s.warn_threshold}` : 'no warn level';
    const c = s.crit_threshold != null ? `crit ${this.comparisonText(s.comparison)}${s.crit_threshold}` : 'no crit level';
    const rule = `The rule grades ${s.metric} at ${w}, ${c} (edit it in OU / Policy).`;
    // No value means no comparison happened — claiming one would be a false reason.
    if (s.value == null) {
      return `${s.state}: no value was reported for ${s.metric}, so nothing could be graded. ${rule}`;
    }
    return `${s.state} because ${s.metric} = ${s.value} against ${w}, ${c}. ${rule}`;
  }
  private comparisonText(c: ServiceState['comparison']): string {
    switch (c) {
      case 'gt': return '> ';
      case 'ge': return '>= ';
      case 'lt': return '< ';
      case 'le': return '<= ';
      case 'eq': return '= ';
      case 'ne': return '!= ';
      default: return '';
    }
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
    this.discoverPercent.set(0);
    this.proposals.set(null);
    this.selected.set(new Set());
    this.creds.set({});
    // The stream emits a progress snapshot every ~500 ms and completes on the done snapshot, which
    // carries the result. Update the bar on each; set proposals only when done.
    this.checkService.discover(this.agent().id).subscribe({
      next: (p) => {
        this.discoverPercent.set(p.percent);
        if (p.error) { this.error.set(p.error); this.discovering.set(false); return; }
        if (p.done && p.result) {
          this.proposals.set(p.result.proposals);
          this.discovering.set(false);
          // Descriptions stay COLLAPSED by default; each expands (and lazy-loads)
          // on click via toggleExpand. Provisioning info also stays lazy.
        }
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
    const id = this.agent().id;
    this.checkService.applyDiscovery(id, assign).subscribe({
      next: () => {
        this.proposals.set(null);
        // Poll right away so the just-assigned checks appear as services now,
        // not only after the next poll cycle (they materialise on evaluation).
        this.rechecking.set(true);
        this.agentService.pollNow(id).subscribe({
          next: () => { this.rechecking.set(false); this.reload(id); },
          error: () => { this.rechecking.set(false); this.reload(id); },
        });
      },
      error: (e) => this.fail(e),
    });
  }
  /** Second entry point to the threshold editor — the FIRST is the Services tab row.
   *
   * Two doors, one editor: this opens the very ThresholdDialogComponent the Services tab opens and
   * posts through the same createCheckRule. That distinction matters. Two entry points to one
   * editor is navigation, and it is what makes a value you are looking at a value you can change.
   * Two DIFFERENT editors for one threshold would be the defect — they could disagree, and the
   * operator would have no way to tell which one won.
   *
   * Before this, the cell showed the threshold and the caption told you to go to OU / Policy or the
   * Services tab: the reason a row is WARN was on screen while the only way to act on it was not.
   */
  editThreshold(s: ServiceState): void {
    const spec = serviceMetricSpec(s.name, s.metric);
    const ref = this.dialog.open(ThresholdDialogComponent, {
      width: 'min(880px, 94vw)',
      maxWidth: '94vw',
      data: {
        hostName: this.agent().name,
        serviceName: s.name,
        // A disk service carries its mount in the name ("Disk /var"); serviceMetricSpec splits that
        // out so the rule is scoped to THAT mount instead of every disk on the host.
        metric: spec?.members[0] ?? s.metric ?? '',
        labelValue: spec?.mount ?? null,
      },
    });
    ref.afterClosed().subscribe((input) => {
      if (!input) return;
      // Reload the service list either way: on success the new grading must be visible, and on
      // failure the row must still show what the host actually has rather than the value we tried.
      this.monitoringService.createCheckRule(input).subscribe({
        next: () => this.refreshServices(),
        error: () => this.refreshServices(),
      });
    });
  }

}
