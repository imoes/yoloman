import { Component, computed, input, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { CompiledHostState, HostInventory } from '../../../core/models/orchestration.model';

interface ThresholdRow {
  service_name?: string;
  metric: string;
  warn?: unknown;
  crit?: unknown;
  comparison?: string;
  source?: string;
}
interface PlanRow {
  name: string;
  version: number | null;
  type: string;
  source: string;
  parameters: Record<string, unknown>;
}
export interface ConfigDesiredResource {
  path: string;
  format: string | null;
  values: Record<string, unknown>;
  source: string;
  key_sources: Record<string, string>;
}
interface ConfigSettingRow {
  key: string;
  value: string;
  source: string;
}

/**
 * gpresult-style report of a host's compiled desired_state: collapsible sections
 * (Summary / Monitoring / Orchestration / Inheritance) with proper tables instead
 * of a raw JSON blob. Every section header toggles open/closed, plus a global
 * "collapse all" / "expand all" — mirrors the Windows RSoP HTML report the user
 * referenced.
 */
@Component({
  selector: 'app-desired-state-report',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="bm-gpr">
      <div class="bm-gpr-top">
        <span class="bm-gpr-title">Resultant desired state</span>
        <input class="bm-gpr-search" type="search" placeholder="Search / filter the desired state…"
               [ngModel]="q()" (ngModelChange)="q.set($event)" />
        @if (ql()) { <span class="bm-gpr-hits">{{ totalHits() }} match{{ totalHits() === 1 ? '' : 'es' }}</span> }
        <button type="button" class="bm-gpr-all" (click)="toggleAll()">{{ allCollapsed() ? 'expand all' : 'collapse all' }}</button>
      </div>

      <!-- Summary -->
      @if (visible('summary')) {
      <section class="bm-gpr-sec">
        <button type="button" class="bm-gpr-h bm-gpr-h1" (click)="toggle('summary')">
          <span class="bm-gpr-caret">{{ open('summary') ? '▾' : '▸' }}</span> Summary
        </button>
        @if (open('summary')) {
          <table class="bm-gpr-kv">
            <tr><th>Host</th><td>{{ state().state.host.name }}</td></tr>
            <tr><th>Organizational unit</th><td>{{ state().state.host.ou ?? '(unassigned)' }}</td></tr>
            <tr><th>Generation</th><td>{{ state().generation }}</td></tr>
            <tr><th>Config hash</th><td class="bm-gpr-mono">{{ state().config_hash }}</td></tr>
            @if (ouPath().length) {
              <tr><th>Inheritance path</th><td>{{ ouPath().join('  ›  ') }}</td></tr>
            }
          </table>
        }
      </section>
      }

      <!-- Monitoring -->
      @if (visible('monitoring')) {
      <section class="bm-gpr-sec">
        <button type="button" class="bm-gpr-h bm-gpr-h1" (click)="toggle('monitoring')">
          <span class="bm-gpr-caret">{{ open('monitoring') ? '▾' : '▸' }}</span> Monitoring
        </button>
        @if (open('monitoring')) {
          <div class="bm-gpr-sub">
            <h4>Applied checks</h4>
            @if (filteredChecks().length) {
              <ul class="bm-gpr-list">@for (c of filteredChecks(); track c) { <li>{{ c }}</li> }</ul>
            } @else { <p class="bm-gpr-empty">No checks apply.</p> }
          </div>
          <div class="bm-gpr-sub">
            <h4>Thresholds</h4>
            @if (filteredThresholds().length) {
              <table class="bm-gpr-tbl">
                <thead><tr><th>Service</th><th>Metric</th><th>Warn</th><th>Crit</th><th>Cmp</th><th>Source</th></tr></thead>
                <tbody>
                  @for (t of filteredThresholds(); track t.metric) {
                    <tr>
                      <td>{{ t.service_name ?? '—' }}</td>
                      <td class="bm-gpr-dim">{{ t.metric }}</td>
                      <td>{{ t.warn ?? '—' }}</td>
                      <td>{{ t.crit ?? '—' }}</td>
                      <td class="bm-gpr-dim">{{ t.comparison ?? '' }}</td>
                      <td><span class="bm-gpr-src">{{ t.source ?? '—' }}</span></td>
                    </tr>
                  }
                </tbody>
              </table>
            } @else { <p class="bm-gpr-empty">No thresholds apply.</p> }
          </div>
          <div class="bm-gpr-sub">
            <h4>Notifications</h4>
            @if (filteredNotifications().length) {
              <ul class="bm-gpr-list">@for (n of filteredNotifications(); track n) { <li>{{ n }}</li> }</ul>
            } @else { <p class="bm-gpr-empty">No notification policies apply.</p> }
          </div>
        }
      </section>
      }

      <!-- Orchestration -->
      @if (visible('orchestration')) {
      <section class="bm-gpr-sec">
        <button type="button" class="bm-gpr-h bm-gpr-h1" (click)="toggle('orchestration')">
          <span class="bm-gpr-caret">{{ open('orchestration') ? '▾' : '▸' }}</span> Orchestration
        </button>
        @if (open('orchestration')) {
          <div class="bm-gpr-sub">
            <h4>Roles</h4>
            @if (filteredRoles().length) {
              <ul class="bm-gpr-list">@for (r of filteredRoles(); track r) { <li>{{ r }}</li> }</ul>
            } @else { <p class="bm-gpr-empty">No orchestration roles.</p> }
          </div>
          <div class="bm-gpr-sub">
            <h4>Applied policies</h4>
            @if (filteredPlans().length) {
              <table class="bm-gpr-tbl">
                <thead><tr><th>Policy</th><th>Type</th><th>Ver</th><th>Origin</th><th>Parameters</th></tr></thead>
                <tbody>
                  @for (p of filteredPlans(); track p.name + p.source) {
                    <tr>
                      <td>{{ p.name }}</td>
                      <td class="bm-gpr-dim">{{ p.type }}</td>
                      <td class="bm-gpr-dim">{{ p.version ?? '—' }}</td>
                      <td><span class="bm-gpr-src">{{ p.source }}</span></td>
                      <td class="bm-gpr-params">{{ paramSummary(p.parameters) }}</td>
                    </tr>
                  }
                </tbody>
              </table>
            } @else { <p class="bm-gpr-empty">No policies apply to this host.</p> }
          </div>
        }
      </section>
      }

      <!-- Configuration -->
      @if (visible('configuration')) {
      <section class="bm-gpr-sec">
        <button type="button" class="bm-gpr-h bm-gpr-h1" (click)="toggle('configuration')">
          <span class="bm-gpr-caret">{{ open('configuration') ? '▾' : '▸' }}</span> Configuration
        </button>
        @if (open('configuration')) {
          @if (filteredConfigFiles().length) {
            @for (f of filteredConfigFiles(); track f.path) {
              <div class="bm-gpr-sub">
                <h4>{{ f.path }} <span class="bm-gpr-src">{{ f.source }}</span></h4>
                @if (f.rows.length) {
                  <table class="bm-gpr-tbl">
                    <thead><tr><th>Setting</th><th>Value</th><th>Source</th></tr></thead>
                    <tbody>
                      @for (r of f.rows; track r.key) {
                        <tr>
                          <td class="bm-gpr-mono">{{ r.key }}</td>
                          <td class="bm-gpr-mono">{{ r.value }}</td>
                          <td><span class="bm-gpr-src">{{ r.source }}</span></td>
                        </tr>
                      }
                    </tbody>
                  </table>
                } @else { <p class="bm-gpr-empty">Whole-file template (no per-key settings).</p> }
              </div>
            }
          } @else {
            <p class="bm-gpr-empty" style="padding: 4px 14px 12px 30px;">No config policies apply to this host.</p>
          }
        }
      </section>
      }

      <!-- Variables (GPO-merged desired-state variables) -->
      @if (visible('variables')) {
      <section class="bm-gpr-sec">
        <button type="button" class="bm-gpr-h bm-gpr-h1" (click)="toggle('variables')">
          <span class="bm-gpr-caret">{{ open('variables') ? '▾' : '▸' }}</span> Variables
        </button>
        @if (open('variables')) {
          @if (filteredVariables().length) {
            <table class="bm-gpr-tbl" style="margin: 4px 0;">
              <thead><tr><th>Variable</th><th>Value</th></tr></thead>
              <tbody>
                @for (v of filteredVariables(); track v.key) {
                  <tr><td class="bm-gpr-mono">{{ v.key }}</td><td class="bm-gpr-mono">{{ v.value }}</td></tr>
                }
              </tbody>
            </table>
          } @else {
            <p class="bm-gpr-empty" style="padding: 4px 14px 12px 30px;">No variables resolve for this host.</p>
          }
        }
      </section>
      }

      <!-- Inventory (document tail) -->
      @if (visible('inventory')) {
      <section class="bm-gpr-sec">
        <button type="button" class="bm-gpr-h bm-gpr-h1" (click)="toggle('inventory')">
          <span class="bm-gpr-caret">{{ open('inventory') ? '▾' : '▸' }}</span> Inventory
        </button>
        @if (open('inventory')) {
          @if (inventory(); as inv) {
            <table class="bm-gpr-kv">
              @if (inv.os) {
                <tr><th>OS</th><td>{{ inv.os.pretty_name || inv.os.distribution }} {{ inv.os.version }}<span class="bm-gpr-dim"> · kernel {{ inv.os.kernel }}</span></td></tr>
              }
              @if (inv.system?.manufacturer || inv.system?.product_name) {
                <tr><th>System</th><td>{{ inv.system?.manufacturer }} {{ inv.system?.product_name }}<span class="bm-gpr-dim">{{ inv.system?.virtualization ? ' · ' + inv.system?.virtualization : '' }}</span></td></tr>
              }
              @if (inv.cpu) {
                <tr><th>CPU</th><td>{{ inv.cpu.model }}<span class="bm-gpr-dim"> · {{ inv.cpu.cores }} cores / {{ inv.cpu.threads }} threads · {{ inv.cpu.architecture }}</span></td></tr>
              }
              @if (inv.memory_mb) {
                <tr><th>Memory</th><td>{{ (inv.memory_mb / 1024).toFixed(1) }} GiB</td></tr>
              }
              @if (inv.disks?.length) {
                <tr><th>Disks</th><td>@for (d of inv.disks; track d.name) { <div>{{ d.name }} — {{ gib(d.size_bytes) }}<span class="bm-gpr-dim">{{ d.model ? ' · ' + d.model : '' }}{{ d.rotational === false ? ' · SSD' : '' }}</span></div> }</td></tr>
              }
              @if (inv.nics?.length) {
                <tr><th>Network</th><td>@for (n of inv.nics; track n.name) { <div>{{ n.name }} <span class="bm-gpr-dim">{{ n.mac }}{{ n.state ? ' · ' + n.state : '' }}</span>{{ (n.ipv4 || []).length ? ' — ' + (n.ipv4 || []).join(', ') : '' }}</div> }</td></tr>
              }
            </table>
            <div class="bm-gpr-sub">
              <h4>Installed packages @if (filteredPackages().length) { <span class="bm-gpr-dim">({{ filteredPackages().length }})</span> }</h4>
              @if (filteredPackages().length) {
                <table class="bm-gpr-tbl">
                  <thead><tr><th>Package</th><th>Version</th><th>Arch</th></tr></thead>
                  <tbody>
                    @for (p of filteredPackages(); track p.name) {
                      <tr><td class="bm-gpr-mono">{{ p.name }}</td><td class="bm-gpr-mono">{{ p.version }}</td><td class="bm-gpr-dim">{{ p.arch }}</td></tr>
                    }
                  </tbody>
                </table>
              } @else {
                <p class="bm-gpr-empty">{{ ql() ? 'No packages match.' : 'Package list not collected yet (the poller gathers it periodically).' }}</p>
              }
            </div>
          } @else {
            <p class="bm-gpr-empty" style="padding: 4px 14px 12px 30px;">No inventory reported for this host yet.</p>
          }
        }
      </section>
      }
    </div>
  `,
  styles: [`
    .bm-gpr { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: hidden; }
    .bm-gpr-top { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 8px 14px; background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); }
    .bm-gpr-title { font-weight: 700; }
    .bm-gpr-search { flex: 1 1 220px; min-width: 140px; padding: 5px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font-size: 12.5px; }
    .bm-gpr-hits { font-size: 12px; opacity: 0.7; white-space: nowrap; }
    .bm-gpr-all { background: none; border: none; color: var(--mat-sys-primary); cursor: pointer; font-size: 13px; white-space: nowrap; }
    .bm-gpr-all:hover { text-decoration: underline; }
    .bm-gpr-sec { border-top: 1px solid var(--mat-sys-outline-variant); }
    .bm-gpr-h { width: 100%; text-align: left; border: none; cursor: pointer; font-weight: 600; padding: 8px 14px; display: flex; align-items: center; gap: 8px; color: inherit; }
    .bm-gpr-h1 { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-gpr-h:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-gpr-caret { width: 12px; opacity: 0.7; }
    .bm-gpr-sub { padding: 4px 14px 12px 30px; }
    .bm-gpr-sub h4 { margin: 12px 0 6px; font-size: 13px; opacity: 0.8; }
    .bm-gpr-kv { border-collapse: collapse; margin: 8px 14px 14px 30px; }
    .bm-gpr-kv th { text-align: left; padding: 4px 24px 4px 0; font-weight: 500; opacity: 0.7; vertical-align: top; white-space: nowrap; }
    .bm-gpr-kv td { padding: 4px 0; }
    .bm-gpr-mono, .bm-gpr-params { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
    .bm-gpr-tbl { width: 100%; border-collapse: collapse; font-size: 13px; }
    .bm-gpr-tbl th { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); font-weight: 600; opacity: 0.8; }
    .bm-gpr-tbl td { padding: 6px 10px; border-bottom: 1px solid color-mix(in srgb, var(--mat-sys-outline-variant) 50%, transparent); vertical-align: top; }
    .bm-gpr-dim { opacity: 0.65; }
    .bm-gpr-src { font-size: 12px; padding: 1px 8px; border-radius: 10px; background: color-mix(in srgb, var(--mat-sys-primary) 15%, transparent); white-space: nowrap; }
    .bm-gpr-list { margin: 4px 0; padding-left: 20px; }
    .bm-gpr-list li { padding: 2px 0; }
    .bm-gpr-empty { opacity: 0.6; font-style: italic; margin: 4px 0; }
    .bm-gpr-params { color: var(--mat-sys-on-surface); opacity: 0.8; max-width: 380px; overflow-wrap: anywhere; }
  `],
})
export class DesiredStateReportComponent {
  state = input.required<CompiledHostState>();
  /** GPO-resolved config files (from GET .../config-desired). Optional — when
   * absent the Configuration section just shows "no config policies". */
  config = input<ConfigDesiredResource[] | null>(null);
  private collapsed = signal<Set<string>>(new Set());
  // Live search/filter over the whole document. While a query is active every
  // section force-expands and shows only matching rows; a section with no match
  // is hidden entirely (see visible()).
  q = signal('');
  ql = computed(() => this.q().trim().toLowerCase());

  open(key: string): boolean {
    if (this.ql()) return true; // searching → expand everything so hits are visible
    return !this.collapsed().has(key);
  }
  toggle(key: string): void {
    const s = new Set(this.collapsed());
    s.has(key) ? s.delete(key) : s.add(key);
    this.collapsed.set(s);
  }
  private readonly sections = ['summary', 'monitoring', 'orchestration', 'configuration', 'variables', 'inventory'];

  /** Does `parts` (any row's text) match the active query? Empty query = all. */
  private hit(...parts: unknown[]): boolean {
    const ql = this.ql();
    if (!ql) return true;
    return parts.some((p) => String(p ?? '').toLowerCase().includes(ql));
  }
  /** A section is shown when not searching, or when it has matching content. */
  visible(key: string): boolean {
    if (!this.ql()) return true;
    switch (key) {
      case 'summary': return this.hit(this.state().state.host.name, this.state().state.host.ou, 'summary host ou generation');
      case 'monitoring': return this.filteredChecks().length > 0 || this.filteredThresholds().length > 0 || this.filteredNotifications().length > 0;
      case 'orchestration': return this.filteredRoles().length > 0 || this.filteredPlans().length > 0;
      case 'configuration': return this.filteredConfigFiles().length > 0;
      case 'variables': return this.filteredVariables().length > 0;
      case 'inventory': return this.filteredPackages().length > 0 || this.hit('inventory os cpu memory disk network');
      default: return true;
    }
  }

  // --- filtered views (identity when the query is empty) ---
  filteredChecks = computed(() => this.state().state.monitoring.checks.filter((c) => this.hit(c)));
  filteredNotifications = computed(() => this.state().state.monitoring.notifications.filter((n) => this.hit(n)));
  filteredRoles = computed(() => this.state().state.orchestration.roles.filter((r) => this.hit(r)));
  filteredThresholds = computed<ThresholdRow[]>(() => this.thresholdRows().filter((t) => this.hit(t.metric, t.service_name, t.source, t.warn, t.crit, t.comparison)));
  filteredPlans = computed<PlanRow[]>(() => this.planRows().filter((p) => this.hit(p.name, p.type, p.source, this.paramSummary(p.parameters))));
  filteredConfigFiles = computed(() => this.configFiles()
    .map((f) => this.hit(f.path, f.source)
      ? f  // whole file matches by path → keep all its rows
      : { ...f, rows: f.rows.filter((r) => this.hit(r.key, r.value, r.source)) })
    .filter((f) => this.hit(f.path, f.source) || f.rows.length > 0));
  filteredVariables = computed<{ key: string; value: string }[]>(() =>
    this.variablesRows().filter((v) => this.hit(v.key, v.value)));
  filteredPackages = computed(() => (this.inventory()?.installed_packages ?? []).filter((p) => this.hit(p.name, p.version, p.arch)));

  variablesRows = computed<{ key: string; value: string }[]>(() => {
    const vars = (this.state().state.variables ?? {}) as Record<string, unknown>;
    return Object.entries(vars)
      .map(([key, v]) => ({ key, value: v === null || v === undefined ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v) }))
      .sort((a, b) => a.key.localeCompare(b.key));
  });

  totalHits = computed<number>(() => {
    if (!this.ql()) return 0;
    return this.filteredChecks().length + this.filteredNotifications().length + this.filteredRoles().length
      + this.filteredThresholds().length + this.filteredPlans().length + this.filteredVariables().length
      + this.filteredConfigFiles().reduce((n, f) => n + Math.max(1, f.rows.length), 0)
      + this.filteredPackages().length;
  });

  inventory = computed<HostInventory | null>(() => this.state().state.inventory ?? null);
  gib(bytes?: number): string {
    if (!bytes) return '—';
    const gib = bytes / 1024 ** 3;
    return gib >= 1 ? `${gib.toFixed(1)} GiB` : `${(bytes / 1024 ** 2).toFixed(0)} MiB`;
  }
  allCollapsed = computed(() => this.sections.every((s) => this.collapsed().has(s)));
  toggleAll(): void {
    this.collapsed.set(this.allCollapsed() ? new Set() : new Set(this.sections));
  }

  ouPath = computed<string[]>(() => {
    const explain = (this.state().explain ?? {}) as { ou_path?: string[] };
    return explain.ou_path ?? [];
  });

  thresholdRows = computed<ThresholdRow[]>(() => {
    const t = (this.state().state.monitoring.thresholds ?? {}) as Record<string, Omit<ThresholdRow, 'metric'>>;
    return Object.entries(t).map(([metric, v]) => ({ metric, ...v }));
  });

  planRows = computed<PlanRow[]>(() => {
    const d = this.state();
    const explain = (d.explain ?? {}) as { assignments?: { plan: string; source: string }[] };
    const sourceByPlan = new Map((explain.assignments ?? []).map((a) => [a.plan, a.source] as const));
    return d.state.orchestration.plans.map((p) => ({
      name: p.name,
      version: p.version,
      type: p.type,
      source: sourceByPlan.get(p.name) ?? 'ou',
      parameters: p.parameters ?? {},
    }));
  });

  configFiles = computed<{ path: string; source: string; rows: ConfigSettingRow[] }[]>(() => {
    const files = this.config() ?? [];
    return files.map((f) => ({
      path: f.path,
      source: f.source,
      rows: this.flatten(f.values, f.key_sources, f.source),
    }));
  });

  /** Flatten a possibly-nested config values object into key/value/source rows.
   * key_sources is keyed by the same flat dot-path effective_resources emits. */
  private flatten(values: Record<string, unknown>, keySources: Record<string, string>, fileSource: string, prefix = ''): ConfigSettingRow[] {
    const rows: ConfigSettingRow[] = [];
    for (const [k, v] of Object.entries(values ?? {})) {
      const key = prefix ? `${prefix}.${k}` : k;
      if (v !== null && typeof v === 'object' && !Array.isArray(v)) {
        rows.push(...this.flatten(v as Record<string, unknown>, keySources, fileSource, key));
      } else {
        rows.push({
          key,
          value: v === null ? '(absent)' : Array.isArray(v) ? v.join(', ') : String(v),
          source: keySources[key] ?? fileSource,
        });
      }
    }
    return rows.sort((a, b) => a.key.localeCompare(b.key));
  }

  paramSummary(params: Record<string, unknown>): string {
    const keys = Object.keys(params ?? {});
    if (!keys.length) return '—';
    return keys.map((k) => `${k}=${typeof params[k] === 'object' ? JSON.stringify(params[k]) : params[k]}`).join(', ');
  }
}
