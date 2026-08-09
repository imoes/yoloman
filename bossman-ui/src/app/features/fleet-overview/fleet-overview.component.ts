import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatDialog } from '@angular/material/dialog';
import { AgentService } from '../../core/services/agent.service';
import { RunService } from '../../core/services/run.service';
import { MonitoringService } from '../../core/services/monitoring.service';
import { SearchService } from '../../core/services/search.service';
import { DashboardService } from '../../core/services/dashboard.service';
import { Agent } from '../../core/models/agent.model';
import { PlanRun } from '../../core/models/run.model';
import { FleetSummary, ServiceState } from '../../core/models/monitoring.model';
import { HostResult, MassAssignFacets, ServiceResult } from '../../core/models/search.model';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { AcknowledgeDialogComponent, AcknowledgeDialogResult } from '../../shared/components/acknowledge-dialog/acknowledge-dialog.component';
import { agentHealthStatus, runStatusBadge, serviceStateBadge } from '../../shared/status.util';
import { DashboardGridComponent } from './dashboard-grid.component';
import { FleetSearchComponent } from './fleet-search.component';

/**
 * The fleet-wide summary landing page (see docs/plan.md's Bossman plan,
 * section C.1, reworked in monitoring Block E4 to lead with CheckMK's own
 * "unbehandelte Probleme" landing principle instead of the earlier
 * host-enrollment-only tiles). The top summary cards + problems panel stay
 * fixed (always-relevant fleet-health KPIs, not something an operator
 * would rearrange); Block F5 adds a real GridStack widget dashboard below
 * them (`<app-dashboard-grid>`) for the part an operator actually wants to
 * customize — see docs/plan.md's Block F5.
 */
@Component({
  selector: 'app-fleet-overview',
  standalone: true,
  imports: [RouterLink, DatePipe, MatCardModule, MatButtonModule, MatIconModule, HostStatusBadgeComponent, DashboardGridComponent, FleetSearchComponent],
  template: `
    <div class="bm-page">
      <div class="bm-page-head">
        <h1>Fleet Overview</h1>
        <a mat-stroked-button routerLink="/ai-dashboard">
          <mat-icon>auto_awesome</mat-icon> AI Dashboard
        </a>
      </div>

      <!-- Checkmk-style omnibox: search fills the page; empty query = the
           standard dashboard below (the "home" you always return to). -->
      <app-fleet-search [seed]="activeQuery()" class="bm-omni-wrap" />

      @if (activeQuery()) {
        <!-- ── search-active: result views ─────────────────────────────── -->
        <div class="bm-results-head bm-noprint">
          <h2>Results for <code>{{ activeQuery() }}</code></h2>
          <span class="bm-spacer"></span>
          @if (pinMsg()) { <span class="bm-bulk-ok">{{ pinMsg() }}</span> }
          @if (hostResults().length) { <button mat-stroked-button (click)="exportHostsCsv()"><mat-icon>download</mat-icon> Hosts CSV</button> }
          @if (serviceResults().length) { <button mat-stroked-button (click)="exportServicesCsv()"><mat-icon>download</mat-icon> Services CSV</button> }
          <button mat-stroked-button (click)="printResults()"><mat-icon>picture_as_pdf</mat-icon> Print / PDF</button>
          <button mat-stroked-button (click)="clearSearch()"><mat-icon>arrow_back</mat-icon> Back to dashboard</button>
        </div>

        <!-- Facet filter bar — point-and-click filters that build the query. -->
        <div class="bm-filter-bar bm-noprint">
          <span class="bm-filter-grp"><span class="bm-filter-lbl">Criticality</span>
            @for (c of critFacets; track c) {
              <button class="bm-chip" [class.on]="facetActive('crit', c)" (click)="toggleFacet('crit', c)">{{ c }}</button>
            }
          </span>
          <span class="bm-filter-grp"><span class="bm-filter-lbl">State</span>
            @for (s of stateFacets; track s) {
              <button class="bm-chip" [class.on]="facetActive('st', s)" (click)="toggleFacet('st', s)" [attr.data-st]="s">{{ s }}</button>
            }
          </span>
          @if (siteOptions().length) {
            <span class="bm-filter-grp"><span class="bm-filter-lbl">Site</span>
              <select class="bm-filter-sel" [value]="currentSiteFacet()" (change)="setSiteFacet($any($event.target).value)">
                <option value="">any</option>
                @for (s of siteOptions(); track s) { <option [value]="s" [selected]="s === currentSiteFacet()">{{ s }}</option> }
              </select>
            </span>
          }
        </div>

        <mat-card class="bm-panel">
          <mat-card-header class="bm-card-head">
            <mat-card-title>Hosts ({{ hostResults().length }})</mat-card-title>
            @if (hostResults().length) {
              <button mat-stroked-button (click)="pinAsWidget('hosts')"><mat-icon>push_pin</mat-icon> Pin as widget</button>
            }
          </mat-card-header>
          <mat-card-content>
            <!-- Bulk-assign bar — appears once ≥1 host is selected. Sets the
                 searchable facets on all selected hosts via P1b's endpoint. -->
            @if (selectedHosts().size) {
              <div class="bm-bulk-bar">
                <span class="bm-bulk-count">{{ selectedHosts().size }} selected</span>
                <label>Criticality
                  <select [value]="bulkCrit()" (change)="bulkCrit.set($any($event.target).value)">
                    <option value="">— keep —</option>
                    <option value="test">test</option>
                    <option value="stage">stage</option>
                    <option value="prod">prod</option>
                    <option value="__clear__">(clear)</option>
                  </select>
                </label>
                <label>Site
                  <input type="text" placeholder="e.g. MUE-0" [value]="bulkSite()" (input)="bulkSite.set($any($event.target).value)" [attr.list]="'bm-sites'" />
                </label>
                <datalist id="bm-sites">@for (s of siteOptions(); track s) { <option [value]="s"></option> }</datalist>
                <label>Tag
                  <input type="text" placeholder="key" [value]="bulkTagKey()" (input)="bulkTagKey.set($any($event.target).value)" class="bm-bulk-tagkey" />
                </label>
                <input type="text" placeholder="value (optional)" [value]="bulkTagVal()" (input)="bulkTagVal.set($any($event.target).value)" class="bm-bulk-tagval" />
                <button mat-raised-button color="primary" (click)="applyBulk()" [disabled]="bulkBusy()">Apply</button>
                <button mat-button (click)="clearSelection()">Clear</button>
                @if (bulkMsg()) { <span class="bm-bulk-ok">{{ bulkMsg() }}</span> }
              </div>
            }
            @if (hostResults().length) {
              <table class="bm-table">
                <thead><tr>
                  <th class="bm-check"><input type="checkbox" [checked]="allHostsSelected()" (change)="toggleAllHosts()" /></th>
                  <th></th><th>Host</th><th>Criticality</th><th>Site</th><th>Groups</th>
                </tr></thead>
                <tbody>
                  @for (h of hostResults(); track h.id) {
                    <tr class="bm-row-link" [class.bm-row-sel]="isSelected(h.id)" [routerLink]="['/hosts', h.id]">
                      <td class="bm-check" (click)="$event.stopPropagation(); $event.preventDefault()">
                        <input type="checkbox" [checked]="isSelected(h.id)" (change)="toggleHost(h.id)" />
                      </td>
                      <td><span class="bm-sq" [style.background]="stateColor(h.state_rollup)" [title]="h.state_rollup"></span></td>
                      <td>{{ h.name }}</td>
                      <td>@if (h.criticality) { <span class="bm-crit-badge" [attr.data-c]="h.criticality">{{ h.criticality }}</span> }</td>
                      <td>{{ h.site || '—' }}</td>
                      <td class="bm-dim">{{ h.groups.join(', ') || '—' }}</td>
                    </tr>
                  }
                </tbody>
              </table>
            } @else { <p class="bm-empty">No matching hosts.</p> }
          </mat-card-content>
        </mat-card>

        <mat-card class="bm-panel">
          <mat-card-header class="bm-card-head">
            <mat-card-title>Service checks ({{ serviceResults().length }})</mat-card-title>
            @if (serviceResults().length) {
              <button mat-stroked-button (click)="pinAsWidget('services')"><mat-icon>push_pin</mat-icon> Pin as widget</button>
            }
          </mat-card-header>
          <mat-card-content>
            @if (serviceResults().length) {
              <table class="bm-table">
                <thead><tr><th>State</th><th>Host</th><th>Service</th><th>Detail</th></tr></thead>
                <tbody>
                  @for (s of serviceResults(); track s.id) {
                    <tr class="bm-row-link" [routerLink]="['/hosts', s.agent_id]" [queryParams]="{ tab: 'services' }">
                      <td><app-status-badge [status]="stateBadge(s.state)" [label]="s.state" /></td>
                      <td>{{ s.host }}</td>
                      <td>{{ s.name }}</td>
                      <td class="bm-detail" [title]="s.output">{{ s.output }}</td>
                    </tr>
                  }
                </tbody>
              </table>
            } @else { <p class="bm-empty">No matching service checks.</p> }
          </mat-card-content>
        </mat-card>
      } @else {

      <!-- CheckMK-style statistics panels (Block H3): Host statistics +
           Service statistics side by side, each a colored-count table —
           the same at-a-glance layout as CheckMK's problems dashboard,
           in the Rastafari palette. -->
      <div class="bm-stats-row">
        <mat-card class="bm-stats-card">
          <div class="bm-stats-title">Host statistics</div>
          <div class="bm-stats-body">
            <div class="bm-stats-total">
              <div class="bm-stats-total-value">{{ summary()?.hosts_total ?? agents().length }}</div>
              <div class="bm-stats-total-label">Total</div>
            </div>
            <table class="bm-stats-table">
              @for (row of hostStats(); track row.label) {
                <tr>
                  <td><span class="bm-sq" [style.background]="row.color"></span></td>
                  <td>{{ row.label }}</td>
                  <td class="bm-stats-count">{{ row.count }}</td>
                </tr>
              }
            </table>
          </div>
        </mat-card>

        <mat-card class="bm-stats-card">
          <div class="bm-stats-title">Service statistics</div>
          <div class="bm-stats-body">
            <div class="bm-stats-total">
              <div class="bm-stats-total-value">{{ servicesTotal() }}</div>
              <div class="bm-stats-total-label">Total</div>
            </div>
            <table class="bm-stats-table">
              <tr>
                <td><span class="bm-sq bm-sq--ok"></span></td>
                <td>OK</td>
                <td class="bm-stats-count">{{ servicesByState().OK }}</td>
              </tr>
              <tr>
                <td><span class="bm-sq bm-sq--warn"></span></td>
                <td>Warning</td>
                <td class="bm-stats-count">{{ servicesByState().WARN }}</td>
              </tr>
              <tr>
                <td><span class="bm-sq bm-sq--crit"></span></td>
                <td>Critical</td>
                <td class="bm-stats-count">{{ servicesByState().CRIT }}</td>
              </tr>
              <tr>
                <td><span class="bm-sq bm-sq--unknown"></span></td>
                <td>Unknown</td>
                <td class="bm-stats-count">{{ servicesByState().UNKNOWN }}</td>
              </tr>
            </table>
          </div>
        </mat-card>

        <mat-card class="bm-stats-card bm-stats-card--problems" routerLink="/problems">
          <div class="bm-stats-title">Open problems</div>
          <div class="bm-stats-problems">
            <div class="bm-stats-total-value" [class.bm-crit]="(summary()?.open_problems ?? 0) > 0" [class.bm-ok]="(summary()?.open_problems ?? 0) === 0">
              {{ summary()?.open_problems ?? 0 }}
            </div>
            <div class="bm-stats-total-label">
              {{ (summary()?.open_problems ?? 0) === 0 ? 'everything irie' : 'unhandled' }}
            </div>
          </div>
        </mat-card>
      </div>

      <mat-card class="bm-panel bm-problems-panel">
        <mat-card-header>
          <mat-card-title>Unhandled problems</mat-card-title>
        </mat-card-header>
        <mat-card-content>
          @if (problems().length) {
            <table class="bm-table">
              <thead>
                <tr>
                  <th>Host</th>
                  <th>Service</th>
                  <th>State</th>
                  <th>Detail</th>
                  <th>Since</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                @for (p of problems(); track p.id) {
                  <tr>
                    <td><a [routerLink]="['/hosts', p.agent_id]" [queryParams]="{ tab: 'services' }">{{ p.agent_name }}</a></td>
                    <td><a class="bm-svc-link" [routerLink]="['/hosts', p.agent_id]" [queryParams]="{ tab: 'services' }">{{ p.name }}</a></td>
                    <td><app-status-badge [status]="badgeOf(p)" [label]="p.state" /></td>
                    <td class="bm-detail" [title]="p.output">{{ p.output }}</td>
                    <td>{{ p.last_state_change | date: 'short' }}</td>
                    <td class="bm-actions">
                      <button mat-button (click)="acknowledge(p)">Acknowledge</button>
                    </td>
                  </tr>
                }
              </tbody>
            </table>
          } @else {
            <p class="bm-empty">No open problems — the fleet is healthy.</p>
          }
        </mat-card-content>
        <mat-card-actions>
          <button mat-button routerLink="/problems">View all problems</button>
        </mat-card-actions>
      </mat-card>

      <app-dashboard-grid class="bm-dashboard-section" />

      <div class="bm-grid">
        <mat-card class="bm-panel">
          <mat-card-header>
            <mat-card-title>Recent Plan Runs</mat-card-title>
          </mat-card-header>
          <mat-card-content>
            @if (recentRuns().length) {
              <table class="bm-table">
                <thead>
                  <tr>
                    <th>Plan</th>
                    <th>Status</th>
                    <th>Started</th>
                  </tr>
                </thead>
                <tbody>
                  @for (run of recentRuns(); track run.id) {
                    <tr [routerLink]="['/runs', run.id]" class="bm-row-link">
                      <td>{{ run.plan_name }}</td>
                      <td><app-status-badge [status]="statusOf(run)" [label]="run.status" /></td>
                      <td>{{ run.started_at | date: 'medium' }}</td>
                    </tr>
                  }
                </tbody>
              </table>
            } @else {
              <p class="bm-empty">No plan runs yet.</p>
            }
          </mat-card-content>
          <mat-card-actions>
            <button mat-button routerLink="/runs">View all runs</button>
          </mat-card-actions>
        </mat-card>

        <mat-card class="bm-panel">
          <mat-card-header>
            <mat-card-title>Quick actions</mat-card-title>
          </mat-card-header>
          <mat-card-content>
            <p>Take a plan and run it against a host.</p>
          </mat-card-content>
          <mat-card-actions>
            <button mat-raised-button color="primary" routerLink="/plans">
              <mat-icon>play_arrow</mat-icon>
              Run a plan
            </button>
            <button mat-button routerLink="/topology">
              <mat-icon>account_tree</mat-icon>
              View topology
            </button>
          </mat-card-actions>
        </mat-card>
      </div>
      }
    </div>
  `,
  styles: [
    `
      .bm-page-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
      }
      .bm-page {
        padding: 24px;
        max-width: 1100px;
        margin: 0 auto;
      }
      .bm-stats-row {
        display: grid;
        grid-template-columns: 1fr 1fr 0.8fr;
        gap: 12px;
        margin-bottom: 20px;
      }
      .bm-stats-card {
        padding: 14px 16px;
        border-top: 3px solid transparent;
        border-image: linear-gradient(90deg, var(--bm-red) 0%, var(--bm-gold) 50%, var(--bm-green) 100%) 1;
      }
      .bm-stats-card--problems {
        cursor: pointer;
        text-align: center;
      }
      .bm-stats-title {
        font-size: 12px;
        text-transform: uppercase;
        letter-spacing: 0.05em;
        opacity: 0.7;
        margin-bottom: 10px;
      }
      .bm-stats-body {
        display: flex;
        align-items: center;
        gap: 20px;
      }
      .bm-stats-total {
        text-align: center;
        min-width: 72px;
      }
      .bm-stats-total-value {
        font-size: 36px;
        font-weight: 700;
        line-height: 1.1;
      }
      .bm-stats-total-label {
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.04em;
        opacity: 0.6;
      }
      .bm-stats-problems {
        padding-top: 4px;
      }
      .bm-stats-table {
        flex: 1;
        border-collapse: collapse;
        font-size: 13px;
      }
      .bm-stats-table td {
        padding: 2px 6px;
      }
      .bm-stats-count {
        text-align: right;
        font-weight: 600;
        font-variant-numeric: tabular-nums;
      }
      .bm-sq {
        display: inline-block;
        width: 12px;
        height: 12px;
        border-radius: 2px;
        background: var(--bm-unknown);
      }
      .bm-sq--ok {
        background: var(--bm-green);
      }
      .bm-sq--warn {
        background: var(--bm-gold);
      }
      .bm-sq--crit {
        background: var(--bm-red);
      }
      .bm-sq--unknown {
        background: var(--bm-unknown);
      }
      @media (max-width: 900px) {
        .bm-stats-row {
          grid-template-columns: 1fr;
        }
      }
      .bm-ok {
        color: var(--bm-green);
      }
      .bm-warn {
        color: var(--bm-gold);
      }
      .bm-crit {
        color: var(--bm-red);
      }
      .bm-unknown {
        color: var(--bm-unknown);
      }
      .bm-problems-panel {
        margin-bottom: 16px;
      }
      .bm-dashboard-section {
        display: block;
        margin-bottom: 16px;
      }
      .bm-grid {
        display: grid;
        grid-template-columns: 2fr 1fr;
        gap: 16px;
      }
      .bm-table {
        width: 100%;
        border-collapse: collapse;
      }
      .bm-table th {
        text-align: left;
        font-size: 12px;
        opacity: 0.7;
        padding: 6px 8px;
      }
      .bm-table td {
        padding: 8px;
        border-top: 1px solid var(--mat-sys-outline-variant);
      }
      .bm-actions {
        text-align: right;
      }
      .bm-row-link {
        cursor: pointer;
      }
      .bm-row-link:hover {
        background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent);
      }
      .bm-empty {
        opacity: 0.6;
      }
      .bm-omni-wrap {
        display: block;
        margin-bottom: 18px;
      }
      .bm-results-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
        margin-bottom: 12px;
      }
      .bm-results-head h2 {
        font-size: 18px;
        font-weight: 600;
      }
      .bm-results-head code {
        background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent);
        padding: 2px 8px;
        border-radius: 6px;
      }
      .bm-crit-badge {
        font-size: 11px;
        text-transform: uppercase;
        padding: 1px 7px;
        border-radius: 10px;
        font-weight: 600;
        background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent);
      }
      .bm-crit-badge[data-c='prod'] { background: color-mix(in srgb, var(--bm-red) 26%, transparent); }
      .bm-crit-badge[data-c='stage'] { background: color-mix(in srgb, var(--bm-gold) 30%, transparent); }
      .bm-crit-badge[data-c='test'] { background: color-mix(in srgb, var(--bm-green) 24%, transparent); }
      .bm-dim { opacity: 0.6; }
      .bm-detail { max-width: 340px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .bm-spacer { flex: 1; }
      .bm-card-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
      .bm-check { width: 34px; text-align: center; }
      .bm-row-sel { background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
      .bm-bulk-bar {
        display: flex; align-items: center; gap: 12px; flex-wrap: wrap;
        padding: 10px 12px; margin-bottom: 10px; border-radius: 8px;
        background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent);
      }
      .bm-bulk-bar label { display: flex; align-items: center; gap: 6px; font-size: 13px; }
      .bm-bulk-bar select, .bm-bulk-bar input {
        padding: 4px 8px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant);
        background: var(--mat-sys-surface); color: var(--mat-sys-on-surface);
      }
      .bm-bulk-tagkey { width: 90px; }
      .bm-bulk-tagval { width: 130px; }
      .bm-bulk-count { font-weight: 600; }
      .bm-bulk-ok { color: var(--bm-green); font-size: 13px; }
      .bm-filter-bar { display: flex; flex-wrap: wrap; gap: 18px; align-items: center; margin-bottom: 14px;
        padding: 10px 12px; border-radius: 8px; background: color-mix(in srgb, var(--mat-sys-on-surface) 4%, transparent); }
      .bm-filter-grp { display: inline-flex; align-items: center; gap: 6px; }
      .bm-filter-lbl { font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; opacity: 0.55; margin-right: 2px; }
      .bm-chip { border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit;
        border-radius: 14px; padding: 3px 12px; font-size: 12.5px; cursor: pointer; }
      .bm-chip:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
      .bm-chip.on { background: color-mix(in srgb, var(--mat-sys-primary) 22%, transparent); border-color: var(--mat-sys-primary); font-weight: 600; }
      .bm-chip[data-st='CRIT'].on { background: color-mix(in srgb, var(--bm-red) 26%, transparent); border-color: var(--bm-red); }
      .bm-chip[data-st='WARN'].on { background: color-mix(in srgb, var(--bm-gold) 30%, transparent); border-color: var(--bm-gold); }
      .bm-filter-sel { padding: 4px 8px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant);
        background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
      @media print {
        .bm-omni-wrap, .bm-noprint, .bm-bulk-bar, .bm-filter-bar { display: none !important; }
        .bm-page { max-width: none; padding: 0; }
        .bm-check { display: none; }
      }
      @media (max-width: 800px) {
        .bm-grid {
          grid-template-columns: 1fr;
        }
      }
    `,
  ],
})
export class FleetOverviewComponent implements OnInit {
  private agentService = inject(AgentService);
  private runService = inject(RunService);
  private monitoringService = inject(MonitoringService);
  private searchService = inject(SearchService);
  private dashboardService = inject(DashboardService);
  private route = inject(ActivatedRoute);
  private router = inject(Router);
  private dialog = inject(MatDialog);

  agents = signal<Agent[]>([]);
  recentRuns = signal<PlanRun[]>([]);
  summary = signal<FleetSummary | null>(null);
  problems = signal<ServiceState[]>([]);

  // Search-driven state: activeQuery empty → the standard dashboard; non-empty
  // → the result views. Driven by the ?q= route param so it's bookmarkable.
  activeQuery = signal('');
  hostResults = signal<HostResult[]>([]);
  serviceResults = signal<ServiceResult[]>([]);

  // P3: row selection + bulk facet assignment on the hosts result view.
  selectedHosts = signal<Set<string>>(new Set());
  bulkCrit = signal('');
  bulkSite = signal('');
  bulkTagKey = signal('');
  bulkTagVal = signal('');
  bulkBusy = signal(false);
  bulkMsg = signal('');
  siteOptions = signal<string[]>([]);

  servicesByState = computed(() => {
    const defaults = { OK: 0, WARN: 0, CRIT: 0, UNKNOWN: 0 };
    return { ...defaults, ...(this.summary()?.services_by_state ?? {}) };
  });

  servicesTotal = computed(() => {
    const s = this.servicesByState();
    return s.OK + s.WARN + s.CRIT + s.UNKNOWN;
  });

  /** CheckMK's host reachability breakdown, derived from the same
   * enrollment/last-seen heuristic every badge in the app uses
   * (agentHealthStatus): ok→Up, unknown/stale→Unreachable, crit
   * (revoked)→Down, warn (pending)→Pending. */
  hostStats = computed(() => {
    const counts = { ok: 0, unknown: 0, crit: 0, warn: 0 };
    for (const a of this.agents()) {
      counts[agentHealthStatus(a)]++;
    }
    return [
      { label: 'Up', count: counts.ok, color: 'var(--bm-green)' },
      { label: 'Unreachable', count: counts.unknown, color: 'var(--bm-unknown)' },
      { label: 'Down', count: counts.crit, color: 'var(--bm-red)' },
      { label: 'Pending', count: counts.warn, color: 'var(--bm-gold)' },
    ];
  });

  ngOnInit(): void {
    this.agentService.list().subscribe((agents) => this.agents.set(agents));
    this.runService.list({ limit: 10 }).subscribe((runs) => this.recentRuns.set(runs));
    this.monitoringService.fleetSummary().subscribe((summary) => this.summary.set(summary));
    this.reloadProblems();

    // React to ?q= — the omnibox routes here; empty = dashboard, else results.
    this.route.queryParamMap.subscribe((pm) => {
      const q = (pm.get('q') || '').trim();
      this.activeQuery.set(q);
      if (q) this.loadResults(q);
    });
  }

  private loadResults(q: string): void {
    this.clearSelection();
    this.searchService.hosts(q).subscribe((r) => this.hostResults.set(r.hosts));
    this.searchService.services(q).subscribe((r) => this.serviceResults.set(r.services));
    this.searchService.sites().subscribe((r) => this.siteOptions.set(r.sites));
  }

  clearSearch(): void {
    this.router.navigate(['/fleet'], { queryParams: { q: null } });
  }

  pinMsg = signal('');

  /** "Als Widget anheften" (P4): save the current query as a query-backed
   * table widget on the standard dashboard — it re-runs the search each load. */
  pinAsWidget(kind: 'hosts' | 'services'): void {
    const q = this.activeQuery();
    if (!q) return;
    this.dashboardService
      .create({
        widget_type: 'table',
        title: `${kind === 'hosts' ? 'Hosts' : 'Services'}: ${q}`,
        gs_w: 4,
        gs_h: 3,
        config: { query: q, kind, limit: 20 },
      })
      .subscribe({
        next: () => this.pinMsg.set(`Pinned to dashboard.`),
        error: () => this.pinMsg.set('Pin failed.'),
      });
  }

  // ── selection ──
  isSelected(id: string): boolean {
    return this.selectedHosts().has(id);
  }

  toggleHost(id: string): void {
    const next = new Set(this.selectedHosts());
    next.has(id) ? next.delete(id) : next.add(id);
    this.selectedHosts.set(next);
  }

  allHostsSelected(): boolean {
    const hosts = this.hostResults();
    return hosts.length > 0 && hosts.every((h) => this.selectedHosts().has(h.id));
  }

  toggleAllHosts(): void {
    this.selectedHosts.set(this.allHostsSelected() ? new Set() : new Set(this.hostResults().map((h) => h.id)));
  }

  clearSelection(): void {
    this.selectedHosts.set(new Set());
    this.bulkMsg.set('');
  }

  // ── bulk facet assign (P1b endpoint) ──
  applyBulk(): void {
    const ids = [...this.selectedHosts()];
    if (!ids.length) return;
    const body: MassAssignFacets = { agent_ids: ids };
    const crit = this.bulkCrit();
    if (crit === '__clear__') body.criticality = '';
    else if (crit) body.criticality = crit;
    if (this.bulkSite().trim()) body.site = this.bulkSite().trim();
    if (this.bulkTagKey().trim()) body.add_tags = { [this.bulkTagKey().trim()]: this.bulkTagVal().trim() };
    if (body.criticality === undefined && body.site === undefined && !body.add_tags) {
      this.bulkMsg.set('Nothing to apply — pick criticality, site or a tag.');
      return;
    }
    this.bulkBusy.set(true);
    this.searchService.bulkAssignFacets(body).subscribe({
      next: (agents) => {
        this.bulkBusy.set(false);
        this.bulkMsg.set(`Updated ${agents.length} host(s).`);
        this.bulkCrit.set('');
        this.bulkSite.set('');
        this.bulkTagKey.set('');
        this.bulkTagVal.set('');
        this.loadResults(this.activeQuery()); // reflect the new facets
      },
      error: () => {
        this.bulkBusy.set(false);
        this.bulkMsg.set('Bulk update failed.');
      },
    });
  }

  stateColor(state: string): string {
    return { OK: 'var(--bm-green)', WARN: 'var(--bm-gold)', CRIT: 'var(--bm-red)' }[state] ?? 'var(--bm-unknown)';
  }

  stateBadge(state: string) {
    return serviceStateBadge(state);
  }

  // ── export (CSV download + browser print→PDF) ──
  private toCsv(headers: string[], rows: (string | number | null | undefined)[][]): string {
    const esc = (v: unknown) => {
      const s = v == null ? '' : String(v);
      return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
    };
    return [headers, ...rows].map((r) => r.map(esc).join(',')).join('\r\n');
  }

  private download(name: string, text: string): void {
    const blob = new Blob([text], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = name;
    a.click();
    URL.revokeObjectURL(url);
  }

  private slug(): string {
    return (this.activeQuery() || 'all').replace(/[^a-z0-9]+/gi, '-').slice(0, 40);
  }

  exportHostsCsv(): void {
    const csv = this.toCsv(
      ['host', 'state', 'criticality', 'site', 'groups', 'address', 'enrollment', 'last_seen'],
      this.hostResults().map((h) => [h.name, h.state_rollup, h.criticality, h.site, h.groups.join(' '), h.address, h.enrollment_state, h.last_seen_at]),
    );
    this.download(`hosts-${this.slug()}.csv`, csv);
  }

  exportServicesCsv(): void {
    const csv = this.toCsv(
      ['host', 'service', 'state', 'metric', 'criticality', 'site', 'output'],
      this.serviceResults().map((s) => [s.host, s.name, s.state, s.metric, s.criticality, s.site, s.output]),
    );
    this.download(`services-${this.slug()}.csv`, csv);
  }

  /** PDF export via the browser's print dialog (Save as PDF) — a print
   * stylesheet hides the nav/chrome so only the result tables print. */
  printResults(): void {
    window.print();
  }

  // ── facet filter bar (point-and-click filters that build the query) ──
  private escRe(s: string): string { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
  private termRe(field: string, value: string): RegExp {
    return new RegExp(`(^|\\s)${field}:"?${this.escRe(value)}"?(?=\\s|$)`, 'i');
  }

  facetActive(field: string, value: string): boolean {
    return this.termRe(field, value).test(this.activeQuery());
  }

  toggleFacet(field: string, value: string): void {
    let q = this.activeQuery().trim();
    if (this.facetActive(field, value)) {
      q = q.replace(this.termRe(field, value), ' ').replace(/\s+/g, ' ').trim();
    } else {
      const term = /\s/.test(value) ? `${field}:"${value}"` : `${field}:${value}`;
      q = `${q} ${term}`.trim();
    }
    this.router.navigate(['/fleet'], { queryParams: { q: q || null } });
  }

  /** Site is single-valued: replace any existing site: term. */
  setSiteFacet(site: string): void {
    let q = this.activeQuery().replace(/(^|\s)site:"?[^\s"]+"?/gi, ' ').replace(/\s+/g, ' ').trim();
    if (site) q = `${q} site:${/\s/.test(site) ? `"${site}"` : site}`.trim();
    this.router.navigate(['/fleet'], { queryParams: { q: q || null } });
  }

  currentSiteFacet(): string {
    const m = /(?:^|\s)site:"?([^\s"]+)"?/i.exec(this.activeQuery());
    return m ? m[1] : '';
  }

  readonly critFacets = ['test', 'stage', 'prod'];
  readonly stateFacets = ['OK', 'WARN', 'CRIT', 'UNKNOWN'];

  private reloadProblems(): void {
    this.monitoringService.problems({ acknowledged: false }).subscribe((problems) => this.problems.set(problems.slice(0, 10)));
  }

  statusOf(run: PlanRun) {
    return runStatusBadge(run.status);
  }

  badgeOf(p: ServiceState) {
    return serviceStateBadge(p.state);
  }

  acknowledge(p: ServiceState): void {
    const ref = this.dialog.open(AcknowledgeDialogComponent, {
      width: '420px',
      data: { serviceName: p.name, hostName: p.agent_name },
    });
    ref.afterClosed().subscribe((result: AcknowledgeDialogResult | undefined) => {
      if (!result) return;
      this.monitoringService
        .acknowledge(p.id, result.comment, result.expireAfterMinutes)
        .subscribe(() => this.reloadProblems());
    });
  }
}
