import { Component, computed, inject, input, output, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatCardModule } from '@angular/material/card';
import { MatIconModule } from '@angular/material/icon';
import { Agent } from '../../../core/models/agent.model';
import { CheckCatalogEntry } from '../../../core/models/check.model';
import { ServiceState } from '../../../core/models/monitoring.model';
import { AgentService } from '../../../core/services/agent.service';
import { CheckService } from '../../../core/services/check.service';
import { MonitoringService } from '../../../core/services/monitoring.service';
import { thresholdContext } from '../../../shared/format.util';
import { availabilityColor } from '../../../shared/status.util';
import { HostConfigScopeService } from '../host-config-scope.service';

/** The Monitoring-thresholds pane, lifted out of host-detail.component.ts.
 *
 * FIRST REAL SLICE of that extraction (host-detail was 4164 lines / ~100 members in nine clusters).
 * It could only be cut once the shared substrate was out: the pane reads the page's apply scope, and
 * before HostConfigScopeService existed, moving it would have COPIED that state — the duplication this
 * codebase keeps paying off.
 *
 * The split of responsibility is deliberate:
 *   * the DATA (the inherited threshold list) stays with the host page, because its category badge
 *     counts it — a second fetch here would mean two sources for one number;
 *   * the EDITOR (the add/edit Miller columns, ~230 lines) lives here;
 *   * `changed` tells the page to reload rather than this component reaching back into it.
 *
 * Template and logic were moved VERBATIM. The only rewrites are the ones the move forces: the apply
 * scope now comes from the injected service, and loadDesiredMonitoring() became changed.emit(). A
 * refactor that also improves the code is a refactor whose regressions cannot be told apart from its
 * improvements.
 *
 * One duplication did collapse on the way, because leaving it would have been copying a known defect:
 * thrScopeFields re-derived the group name by hand, which the scope service already answers.
 */
@Component({
  selector: 'app-host-thresholds',
  standalone: true,
  imports: [MatButtonModule, MatCardModule, MatIconModule],
  template: `
            <h3 class="bm-gpo-h">
              Monitoring thresholds
              <button mat-button (click)="startAddThr()" [disabled]="thrBusy()">
                <mat-icon>add</mat-icon> Add threshold
              </button>
            </h3>
            <!-- The table lists the thresholds the host INHERITS (compiled
                 desired state). A metric nobody has a rule for isn't in it
                 yet, so adding one needs its own affordance. -->
            @if (addThr()) {
              <mat-card class="bm-setting-dlg">
                <strong>New threshold</strong>
                <p class="bm-dim">Pick a check configured on this host, then set its warn/crit. Everything is documented — the selected check's description is shown on the right.</p>
                <div class="bm-thr-miller">
                  <!-- Column 1: the checks/services configured on this host -->
                  <div class="bm-thr-col bm-thr-checks">
                    <input class="bm-kvin bm-thr-search" type="search" placeholder="filter checks…" [value]="thrSearch()" (input)="thrSearch.set($any($event.target).value)" />
                    @for (s of addThrServices(); track s.id) {
                      <div class="bm-thr-item" [class.sel]="newMetric() === s.metric && newService() === s.name" (click)="pickThrService(s)">
                        <span class="bm-thr-dot" [style.background]="availabilityColor(s.state)"></span>
                        <span class="bm-thr-item-name">{{ s.name }}</span>
                        <span class="bm-thr-item-metric">{{ s.metric }}</span>
                      </div>
                    } @empty { <p class="bm-dim bm-thr-pad">No checks match.</p> }
                    <div class="bm-thr-other" [class.sel]="thrOther()" (click)="pickThrOther()">
                      <mat-icon>tune</mat-icon> Other metric…
                    </div>
                  </div>
                  <!-- Column 2: description + the threshold settings -->
                  <div class="bm-thr-col bm-thr-settings">
                    @if (newMetric() || thrOther()) {
                      <div class="bm-thr-desc">
                        <div class="bm-thr-desc-h">{{ newService() || newMetric() || 'New check' }}</div>
                        <pre class="bm-thr-desc-body">{{ thrDesc() }}</pre>
                      </div>
                      @if (thrOther()) {
                        <label>Metric
                          <input class="bm-kvin" list="bm-metric-options" [value]="newMetric()"
                                 (input)="onNewMetric($any($event.target).value)" placeholder="e.g. uptime_seconds" />
                          <datalist id="bm-metric-options">
                            @for (m of metricOptions(); track m) { <option [value]="m"></option> }
                          </datalist>
                        </label>
                        <label>Service <input class="bm-kvin" [value]="newService()" (input)="newService.set($any($event.target).value)" placeholder="display name" /></label>
                      }
                      <div class="bm-thr-inputs">
                        <label>Comparison
                          <select class="bm-kvin" [value]="newComparison()" (change)="newComparison.set($any($event.target).value)">
                            @for (c of comparisons; track c.v) { <option [value]="c.v">{{ c.label }}</option> }
                          </select>
                        </label>
                        <label>Warn <input class="bm-kvin" [value]="newWarn()" (input)="newWarn.set($any($event.target).value)" /></label>
                        <label>Crit <input class="bm-kvin" [value]="newCrit()" (input)="newCrit.set($any($event.target).value)" /></label>
                      </div>
                      <label class="bm-scope">Scope:
                        <select [value]="applyScope()" (change)="applyScope.set($any($event.target).value)">
                          <option value="host">this host</option>
                          @if (agent().ou_id) { <option value="ou">OU (every host under it)</option> }
                          @for (g of hostGroups(); track g.id) { <option [value]="'group:' + g.id">group {{ g.name }}</option> }
                        </select>
                      </label>
                      <p class="bm-dim">A threshold set here always wins over a policy — it appears in the
                        desired state with source <code>host:…</code> once the change is compiled.</p>
                      @if (thrError(); as te) { <p class="bm-cfg-err">{{ te }}</p> }
                    } @else {
                      <p class="bm-dim bm-thr-pad">Pick a check on the left to set its warn/crit — its description appears here.</p>
                    }
                    <div class="bm-rollback-actions">
                      <button mat-button (click)="addThr.set(false)" [disabled]="thrBusy()">Cancel</button>
                      <button mat-flat-button color="primary" (click)="createThr()" [disabled]="thrBusy() || !newMetric().trim()">Add</button>
                    </div>
                  </div>
                </div>
              </mat-card>
            }
            <table class="bm-gpo-settings">
              <thead><tr><th>Service</th><th>Metric</th><th>Warn</th><th>Crit</th><th>Source</th></tr></thead>
              <tbody>
                @for (t of thresholds(); track t.metric) {
                  <tr (click)="openThr(t)" [class.bm-row-sel]="thrKey() === t.metric">
                    <td>{{ t.service_name ?? '—' }}</td><td class="bm-gpo-key">{{ t.metric }}</td>
                    <td>{{ t.warn ?? '—' }}</td><td>{{ t.crit ?? '—' }}</td>
                    <td><span class="bm-tag">{{ t.source ?? '—' }}</span></td>
                  </tr>
                }
              </tbody>
            </table>
            @if (thrKey(); as tk) {
              <mat-card class="bm-setting-dlg">
                <strong>{{ tk }}</strong>
                <label class="bm-radio"><input type="radio" name="thrmode" [checked]="thrMode() === 'configured'" (change)="thrMode.set('configured')" /> Configured at this scope</label>
                @if (thrMode() === 'configured') {
                  <div class="bm-thr-inputs">
                    <label>Warn <input class="bm-kvin" [value]="thrWarn()" (input)="thrWarn.set($any($event.target).value)" /></label>
                    <label>Crit <input class="bm-kvin" [value]="thrCrit()" (input)="thrCrit.set($any($event.target).value)" /></label>
                  </div>
                }
                <label class="bm-radio"><input type="radio" name="thrmode" [checked]="thrMode() === 'notconf'" (change)="thrMode.set('notconf')" /> Not configured at this scope (remove the rule)</label>
                <label class="bm-scope">Scope:
                  <select [value]="applyScope()" (change)="applyScope.set($any($event.target).value)">
                    <option value="host">this host</option>
                    @if (agent().ou_id) { <option value="ou">OU (every host under it)</option> }
                    @for (g of hostGroups(); track g.id) { <option [value]="'group:' + g.id">group {{ g.name }}</option> }
                  </select>
                </label>
                @if (thrError(); as te) { <p class="bm-cfg-err">{{ te }}</p> }
                <div class="bm-rollback-actions">
                  <button mat-button (click)="thrKey.set(null)" [disabled]="thrBusy()">Cancel</button>
                  <button mat-flat-button color="primary" (click)="applyThr()" [disabled]="thrBusy()">Apply</button>
                </div>
              </mat-card>
            }
  `,
})
export class HostThresholdsComponent {
  private agentService = inject(AgentService);
  private checkService = inject(CheckService);
  private monitoringService = inject(MonitoringService);
  private scope = inject(HostConfigScopeService);

  /** The host being edited. */
  agent = input.required<Agent>();
  /** Its live monitoring services — the left Miller column of "Add threshold". */
  services = input.required<ServiceState[]>();
  /** The thresholds the host INHERITS (compiled desired state), owned by the page. */
  thresholds = input.required<{ metric: string; service_name?: string; warn?: number | null; crit?: number | null; comparison?: string; source?: string }[]>();
  /** Something was written — the page reloads its list (and its badge count) rather than this
   * component mutating an input it does not own. */
  changed = output<void>();

  /** The shared apply scope, exposed so the moved template keeps its original bindings. */
  applyScope = this.scope.applyScope;
  hostGroups = this.scope.hostGroups;
  availabilityColor = availabilityColor;

  readonly comparisons = [
    { v: 'ge', label: '≥ (at or above)' }, { v: 'gt', label: '> (above)' },
    { v: 'le', label: '≤ (at or below)' }, { v: 'lt', label: '< (below)' },
    { v: 'eq', label: '= (equals)' }, { v: 'ne', label: '≠ (differs)' },
  ];

  private thrCatalog = signal<CheckCatalogEntry[]>([]);
  thrKey = signal<string | null>(null);
  thrMode = signal<'configured' | 'notconf'>('configured');
  thrWarn = signal('');
  thrCrit = signal('');
  thrBusy = signal(false);
  thrError = signal<string | null>(null);
  openThr(t: { metric: string; warn?: number | null; crit?: number | null }): void {
    this.thrKey.set(t.metric);
    this.thrWarn.set(t.warn === null || t.warn === undefined ? '' : String(t.warn));
    this.thrCrit.set(t.crit === null || t.crit === undefined ? '' : String(t.crit));
    this.thrMode.set('configured');
    this.thrError.set(null);
  }
  // --- add a NEW threshold -------------------------------------------------
  // The table above lists what the host INHERITS (from the compiled desired
  // state), so a metric that has no rule anywhere never appears and could not be
  // configured. This adds one; the metric list is seeded from the host's own
  // metrics so it stays a choice rather than free-text guessing.
  addThr = signal(false);
  newMetric = signal('');
  newService = signal('');
  newComparison = signal('ge');
  newWarn = signal('');
  newCrit = signal('');
  metricOptions = signal<string[]>([]);
  startAddThr(): void {
    this.addThr.set(true);
    this.thrKey.set(null);
    this.thrError.set(null);
    this.newMetric.set(''); this.newService.set(''); this.newWarn.set(''); this.newCrit.set('');
    // The check catalog (name, short_description, summary) — so a picked service
    // can show its real check description (the yaml text), not just a glossary.
    if (!this.thrCatalog().length) {
      this.checkService.listChecks().subscribe({
        next: (r) => this.thrCatalog.set(r.checks || []),
        error: () => this.thrCatalog.set([]),
      });
    }
    const agent = this.agent();
    if (agent && !this.metricOptions().length) {
      // the host's own metric names, minus the ones that already have a threshold
      this.agentService.metricNames(agent.id).subscribe({
        next: (r) => {
          const taken = new Set(this.thresholds().map((t) => t.metric));
          this.metricOptions.set([...new Set(r.metrics ?? [])].filter((m) => !taken.has(m)).sort());
        },
        error: () => this.metricOptions.set([]),
      });
    }
  }
  /** Pre-fill a readable service name from the metric (user can override). */
  onNewMetric(v: string): void {
    this.newMetric.set(v);
    if (!this.newService().trim()) {
      this.newService.set(v.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase()));
    }
    this.thrDesc.set(this.metricGlossary(v) || 'A custom metric threshold. Warn/crit grade the reported value.');
  }
  // ---- Add-threshold Miller: pick a check configured on the host ----------
  thrSearch = signal('');
  thrOther = signal(false);
  thrDesc = signal('');
  /** The checks configured on this host = its monitored services, filtered by
   * the search box. This is the left Miller column of Add threshold. */
  addThrServices = computed<ServiceState[]>(() => {
    const q = this.thrSearch().trim().toLowerCase();
    return this.services()
      .filter((s) => s.metric && s.name !== 'Config drift' ? true : !!s.metric)
      .filter((s) => !q || s.name.toLowerCase().includes(q) || (s.metric || '').toLowerCase().includes(q))
      .slice()
      .sort((a, b) => a.name.localeCompare(b.name));
  });
  /** Pick a host check → prefill the threshold form from it + show its
   * description (self-explaining: what it measures, its live result, and what
   * it is currently graded against). */
  pickThrService(s: ServiceState): void {
    this.thrOther.set(false);
    this.newMetric.set(s.metric);
    this.newService.set(s.name);
    if (s.comparison) this.newComparison.set(s.comparison);
    if (s.warn_threshold !== null && s.warn_threshold !== undefined) this.newWarn.set(String(s.warn_threshold));
    if (s.crit_threshold !== null && s.crit_threshold !== undefined) this.newCrit.set(String(s.crit_threshold));
    // Show the real check description. Live parts first so something is always
    // there; the check's yaml description is fetched + prepended when resolved.
    const live: string[] = [];
    if (s.output) live.push(`Latest result: ${s.output}`);
    const graded = thresholdContext(s);
    if (graded) live.push(`Currently graded: ${graded}.`);
    live.push(`Metric: ${s.metric}.`);
    const compose = (desc: string) => this.thrDesc.set([desc, ...live].filter(Boolean).join('\n\n'));
    compose(this.metricGlossary(s.metric));

    // Resolve the check's real description. Try the best candidate names in turn
    // (catalog match, the raw service name, the metric) — robust even if the
    // catalog hasn't loaded yet, since services are often named after their check.
    const match = this.matchCheckForService(s);
    const candidates = [...new Set([match?.name, s.name, s.metric].filter((x): x is string => !!x))];
    const tryNext = (i: number): void => {
      if (i >= candidates.length) { if (match?.summary) compose(match.summary); return; }
      this.checkService.getCheck(candidates[i]).subscribe({
        next: (r) => {
          const d = (r as { metadata?: { description?: string } })?.metadata?.description || '';
          if (d) compose(d); else tryNext(i + 1);
        },
        error: () => tryNext(i + 1),
      });
    };
    tryNext(0);
  }
  /** Best-effort map from a running service to its library check, so we can show
   * the check's own description. Match on the service-name template (short_desc
   * with %s stripped) exactly or as a prefix, else on the metric/name token. */
  private matchCheckForService(s: ServiceState): CheckCatalogEntry | null {
    const cat = this.thrCatalog();
    if (!cat.length) return null;
    const label = (c: CheckCatalogEntry) => (c.short_description || '').replace(/%s/g, '').replace(/\s+/g, ' ').trim().toLowerCase();
    const sn = (s.name || '').trim().toLowerCase();
    const metric = (s.metric || '').trim().toLowerCase();
    // Exact raw name/metric first (services named after their check, e.g.
    // systemd_units_services_summary); then the service-name template exactly;
    // then as a prefix at a word boundary. No loose substring — "md" must not
    // match "systemd…".
    return cat.find((c) => c.name && (c.name.toLowerCase() === sn || c.name.toLowerCase() === metric))
      || cat.find((c) => label(c) && label(c) === sn)
      || cat.find((c) => label(c) && (sn === label(c) || sn.startsWith(label(c) + ' ')))
      || null;
  }
  pickThrOther(): void {
    this.thrOther.set(true);
    this.newMetric.set(''); this.newService.set('');
    this.thrDesc.set('Set a threshold on any metric this host reports, even one without a service yet. Start typing a metric name.');
  }
  /** One-line "what this measures" for the common builtin metrics, so the
   * threshold editor is self-documenting even for metrics without a library
   * check description. */
  private metricGlossary(metric: string): string {
    const m = (metric || '').toLowerCase();
    const G: [RegExp, string][] = [
      [/cpu_load|load1|load5|load15/, 'System load average — the mean number of processes waiting to run; compare against the core count.'],
      [/cpu.*pct|cpu.*percent|cpu_usage/, 'CPU utilisation in percent across all cores.'],
      [/mem.*used.*pct|mem.*percent|memory.*used/, 'RAM in use as a percent of total physical memory.'],
      [/swap/, 'Swap space in use — sustained swapping indicates memory pressure.'],
      [/disk.*used.*pct|fs.*used|filesystem/, 'Filesystem usage in percent; crit before it fills up.'],
      [/disk.*io|iops|read_bytes|write_bytes/, 'Disk I/O throughput / operations per second.'],
      [/uptime/, 'Time since last boot — a sudden drop means the host rebooted.'],
      [/net.*rx|net.*tx|bandwidth|throughput/, 'Network throughput on the interface.'],
      [/temp|temperature/, 'Hardware temperature sensor reading.'],
      [/process|proc_/, 'Per-process resource usage.'],
      [/config_drift/, 'Number of managed config files drifted from desired (out-of-band changes).'],
    ];
    for (const [re, desc] of G) if (re.test(m)) return desc;
    return '';
  }
  createThr(): void {
    const agent = this.agent();
    const metric = this.newMetric().trim();
    if (!agent || !metric) return;
    this.thrBusy.set(true);
    this.thrError.set(null);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const body: any = {
      service_name: this.newService().trim() || metric,
      metric,
      comparison: this.newComparison(),
      warn_threshold: this.newWarn() === '' ? null : Number(this.newWarn()),
      crit_threshold: this.newCrit() === '' ? null : Number(this.newCrit()),
      ...this.thrScopeFields(agent),
      enabled: true,
    };
    if (body.warn_threshold === null && body.crit_threshold === null) {
      this.thrError.set('set at least a warn or a crit value');
      this.thrBusy.set(false);
      return;
    }
    this.monitoringService.createCheckRule(body).subscribe({
      next: () => { this.thrBusy.set(false); this.addThr.set(false); this.changed.emit(); },
      error: (e: { error?: { detail?: string } }) => {
        this.thrError.set(e?.error?.detail ?? 'failed'); this.thrBusy.set(false);
      },
    });
  }
  /** The CheckRule scope fields for the currently selected apply-scope. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private thrScopeFields(agent: { name: string; ou_id?: string | null }): any {
    const scope = this.scope.applyScope();
    if (scope === 'ou') return { scope_type: 'ou', scope_ou_id: agent.ou_id, scope_value: null };
    if (scope.startsWith('group:')) {
      return { scope_type: 'group', scope_ou_id: null,
               scope_value: this.scope.groupName() };
    }
    return { scope_type: 'host', scope_value: agent.name, scope_ou_id: null };
  }
  applyThr(): void {
    const agent = this.agent();
    const metric = this.thrKey();
    if (!agent || !metric) return;
    const t = this.thresholds().find((x) => x.metric === metric);
    const scope = this.scope.applyScope();
    const scopeFields = scope === 'ou'
      ? { scope_type: 'ou', scope_ou_id: agent.ou_id, scope_value: null }
      : scope.startsWith('group:')
        ? { scope_type: 'group', scope_value: this.scope.groupName(), scope_ou_id: null }
        : { scope_type: 'host', scope_value: agent.name, scope_ou_id: null };
    this.thrBusy.set(true);
    this.thrError.set(null);
    const done = () => { this.thrBusy.set(false); this.thrKey.set(null); this.changed.emit(); };
    const fail = (e: { error?: { detail?: string } }) => { this.thrError.set(e?.error?.detail ?? 'failed'); this.thrBusy.set(false); };
    this.monitoringService.listCheckRules().subscribe({
      next: (rules) => {
        const existing = rules.find((ru) =>
          ru.metric === metric && ru.scope_type === scopeFields.scope_type &&
          (scopeFields.scope_type === 'ou' ? ru.scope_ou_id === agent.ou_id : ru.scope_value === scopeFields.scope_value));
        if (this.thrMode() === 'notconf') {
          if (!existing) { this.thrError.set('no rule at this scope to remove'); this.thrBusy.set(false); return; }
          this.monitoringService.deleteCheckRule(existing.id).subscribe({ next: done, error: fail });
          return;
        }
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const body: any = {
          service_name: t?.service_name ?? metric, metric, comparison: t?.comparison ?? 'ge',
          warn_threshold: this.thrWarn() === '' ? null : Number(this.thrWarn()),
          crit_threshold: this.thrCrit() === '' ? null : Number(this.thrCrit()),
          ...scopeFields, enabled: true,
        };
        if (existing) this.monitoringService.updateCheckRule(existing.id, body).subscribe({ next: done, error: fail });
        else this.monitoringService.createCheckRule(body).subscribe({ next: done, error: fail });
      },
      error: fail,
    });
  }

}
