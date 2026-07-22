import { Component, Inject, computed, inject, signal, viewChildren } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { from, of, catchError, map, concatMap, toArray } from 'rxjs';
import { CatalogPackage } from '../../../../core/services/package-catalog.service';
import { WizardContext, WizardRunbook, WizardService, RunbookRunResult } from '../../../../core/services/wizard.service';
import { CheckService } from '../../../../core/services/check.service';
import { AgentService } from '../../../../core/services/agent.service';
import { ObservedResource } from '../../../../core/models/agent.model';
import { ParamFormComponent } from '../../../../shared/param-form/param-form.component';

// Category column ordering + display for the role browser (Miller column 1).
const CAT_ORDER = ['web', 'database', 'services', 'network', 'security', 'storage', 'virtualization', 'logging', 'time', 'system', 'other'];
const CAT_META: Record<string, { label: string; icon: string }> = {
  web: { label: 'Web', icon: 'language' },
  database: { label: 'Database', icon: 'storage' },
  services: { label: 'Services', icon: 'apps' },
  network: { label: 'Network', icon: 'lan' },
  security: { label: 'Security', icon: 'security' },
  storage: { label: 'Storage', icon: 'save' },
  virtualization: { label: 'Virtualization', icon: 'dns' },
  logging: { label: 'Logging', icon: 'article' },
  time: { label: 'Time', icon: 'schedule' },
  system: { label: 'System', icon: 'settings' },
  other: { label: 'Other', icon: 'folder' },
};

export interface AddRolesWizardData {
  agentId: string;
  hostName: string;
  catalog: Record<string, CatalogPackage>;
  context: WizardContext;
  preselect?: string; // jump straight to configuring one already-installed package
}

interface RunState { pkg: string; result?: RunbookRunResult; error?: string; running?: boolean; }

/** "Add Roles and Features" — guided role install wizard.
 * Before You Begin → Select Roles → Configure each → Confirmation → Results.
 * Installs packages and renders their config via the seeded install-<pkg>
 * runbooks, entirely inside the management console. */
@Component({
  selector: 'app-add-roles-wizard',
  standalone: true,
  imports: [FormsModule, MatDialogModule, MatButtonModule, MatIconModule, MatCheckboxModule, MatProgressSpinnerModule, ParamFormComponent],
  template: `
    <div class="bm-wz">
      <div class="bm-wz-title">Add Roles and Features <span class="bm-wz-host">{{ data.hostName }}</span></div>
      <div class="bm-wz-body">
        <!-- Left vertical step list -->
        <nav class="bm-wz-steps">
          @for (s of stepLabels(); track $index) {
            <div class="bm-wz-step" [class.bm-wz-step--cur]="step() === $index" [class.bm-wz-step--done]="step() > $index">
              <span class="bm-wz-step-ic">@if (step() > $index) { <mat-icon>check</mat-icon> } @else { {{ $index + 1 }} }</span>
              {{ s }}
            </div>
          }
        </nav>

        <!-- Main -->
        <section class="bm-wz-main">
          @switch (stepKind()) {
            @case ('before') {
              <h2>Before you begin</h2>
              <p class="bm-wz-lead">This wizard installs server roles on <strong>{{ data.hostName }}</strong> and configures them.
                Detected OS family: <strong>{{ data.context.family }}</strong>. Nothing is changed until the final Install step;
                you can preview (dry-run) on the Confirmation page.</p>
            }
            @case ('select') {
              <h2>Select roles</h2>
              <p class="bm-wz-lead">Pick the roles to install on this host — browse by category.</p>
              <input class="bm-wz-search" placeholder="Search roles…" [ngModel]="roleQuery()" (ngModelChange)="roleQuery.set($event)" />
              <!-- Miller columns: category → packages (with description) → detail -->
              <div class="bm-wz-miller">
                <div class="bm-wz-mcol bm-wz-mcol--cats">
                  @for (c of catsOrdered(); track c.category) {
                    <div class="bm-wz-mcat" [class.bm-wz-msel]="effectiveCat() === c.category" (click)="activeCat.set(c.category)">
                      <mat-icon class="bm-wz-mcat-ic">{{ catIcon(c.category) }}</mat-icon>
                      <span class="bm-wz-mcat-lbl">{{ catName(c.category) }}</span>
                      <span class="bm-wz-mcount">{{ c.items.length }}</span>
                    </div>
                  } @empty { <div class="bm-wz-dim bm-wz-mpad">No roles match.</div> }
                </div>
                <div class="bm-wz-mcol bm-wz-mcol--pkgs">
                  @for (r of catItems(); track r.name) {
                    <div class="bm-wz-mrole" [class.bm-wz-msel]="focus() === r.name" (click)="focus.set(r.name)">
                      <mat-checkbox [checked]="picked().has(r.name)" [disabled]="isInstalled(r.name)"
                        (change)="toggle(r.name)" (click)="$event.stopPropagation()" />
                      <mat-icon class="bm-wz-role-ic">{{ r.icon }}</mat-icon>
                      <div class="bm-wz-mrole-txt">
                        <div class="bm-wz-mrole-lbl">{{ r.label }}@if (isInstalled(r.name)) { <span class="bm-wz-badge">Installed</span> }</div>
                        <div class="bm-wz-mrole-desc">{{ r.description }}</div>
                      </div>
                    </div>
                  } @empty { <div class="bm-wz-dim bm-wz-mpad">Pick a category.</div> }
                </div>
                <aside class="bm-wz-mcol bm-wz-desc">
                  @if (focused(); as r) {
                    <div class="bm-wz-desc-lbl">{{ r.label }}</div>
                    <p>{{ r.description }}</p>
                    <div class="bm-wz-desc-pkg">Package: <code>{{ resolvedPackages(r.name) }}</code></div>
                    @if (isInstalled(r.name)) { <div class="bm-wz-desc-pkg">Status: <strong>installed</strong> — "Configure" reloads its current settings.</div> }
                    @if (!r.template) { <div class="bm-wz-warn">No configuration template yet — installs with defaults, no Configure step.</div> }
                  } @else { <p class="bm-wz-dim">Select a role to see what it does.</p> }
                </aside>
              </div>
            }
            @case ('cfg') {
              <h2>Configure {{ cfgLabel() }}</h2>
              <p class="bm-wz-lead">Set the configuration for {{ cfgLabel() }}. Defaults are shown for every setting.</p>
              @if (prefilled(cfgPkg())) {
                <p class="bm-wz-prefill"><mat-icon>download_done</mat-icon> Current settings read from {{ data.hostName }} and pre-filled below — edit to change.</p>
              }
              @if (rb(cfgPkg()); as r) {
                <app-param-form [params]="r.parameters" [initial]="initialFor(cfgPkg())" (valuesChange)="setValues(cfgPkg(), $event)" />
              } @else {
                <p class="bm-wz-dim">Loading configuration form…</p>
              }
            }
            @case ('confirm') {
              <h2>Confirmation</h2>
              <p class="bm-wz-lead">Review what will be installed and configured, then Install (or preview with a dry run).</p>
              @for (p of toInstall(); track p) {
                <div class="bm-wz-sum">
                  <div class="bm-wz-sum-h">{{ catLabel(p) }}</div>
                  <dl class="bm-wz-dl">
                    <dt>Install</dt><dd class="bm-mono">{{ resolvedPackages(p) }}</dd>
                    @if (data.catalog[p].template) {
                      <dt>Configure</dt><dd class="bm-mono">{{ data.context.catalog_resolved[p].config_path }}</dd>
                    }
                    <dt>Service</dt><dd class="bm-mono">{{ data.context.catalog_resolved[p].service }} — restart + enable</dd>
                  </dl>
                </div>
              }
              @if (dryRun(); as dr) {
                <div class="bm-wz-dry">
                  <div class="bm-wz-dry-h">Dry-run preview</div>
                  @for (rs of dr; track rs.pkg) {
                    <div><strong>{{ catLabel(rs.pkg) }}</strong>: {{ summarize(rs) }}</div>
                  }
                </div>
              }

              <label class="bm-wz-mon">
                <mat-checkbox [ngModel]="setupMonitoring()" (ngModelChange)="setupMonitoring.set($event)"></mat-checkbox>
                <span>Set up a monitoring check for each role <span class="bm-wz-dim">— a service-health check configured from the role's service</span></span>
              </label>

              <!-- Wizard = runbook: the composed runbook (role calls + your
                   variables), copyable, and savable as a reusable template
                   BEFORE installing — editable later in the Workflow designer. -->
              <details class="bm-wz-tpl">
                <summary>Runbook &amp; invocation <span class="bm-wz-dim">— this is what runs; save or copy it</span></summary>
                <div class="bm-wz-tpl-bar">
                  <input class="bm-wz-tpl-name" placeholder="template name (optional)" [ngModel]="templateName()" (ngModelChange)="templateName.set($event)" />
                  <button mat-stroked-button (click)="copyTemplate()"><mat-icon>content_copy</mat-icon> Copy</button>
                  <button mat-stroked-button (click)="saveAsTemplate()"><mat-icon>save</mat-icon> Save as template</button>
                  @if (savedMsg()) { <span class="bm-wz-saved">{{ savedMsg() }}</span> }
                </div>
                <pre class="bm-wz-nt">{{ templateNt() }}</pre>
              </details>
            }
            @case ('results') {
              <h2>Results</h2>
              @for (rs of runStates(); track rs.pkg) {
                <div class="bm-wz-result">
                  <div class="bm-wz-result-h">
                    @if (rs.running) { <mat-spinner diameter="16" /> } @else if (rs.error || rs.result?.aborted || rs.result?.ok === false) { <mat-icon class="bm-err">error</mat-icon> } @else { <mat-icon class="bm-ok">check_circle</mat-icon> }
                    {{ catLabel(rs.pkg) }}
                  </div>
                  @if (rs.error) { <div class="bm-wz-err">{{ rs.error }}</div> }
                  @for (st of rs.result?.steps || []; track st.name) {
                    <div class="bm-wz-stepr">
                      <mat-icon class="{{ st.status === 'failed' ? 'bm-err' : 'bm-ok' }}">{{ st.status === 'failed' ? 'error' : (st.status === 'skipped' ? 'remove' : 'check') }}</mat-icon>
                      <span>{{ st.name }}</span><span class="bm-wz-stepr-s">{{ st.status }}</span>
                    </div>
                    @if (st.error) { <div class="bm-wz-err">{{ st.error }}</div> }
                  }
                </div>
              }
            }
          }
        </section>
      </div>

      <!-- Footer -->
      <div class="bm-wz-footer">
        <button mat-button (click)="close()">{{ finished() ? 'Close' : 'Cancel' }}</button>
        <span class="bm-wz-spacer"></span>
        @if (!finished()) {
          <button mat-stroked-button [disabled]="step() === 0 || busy()" (click)="prev()">Previous</button>
          @if (stepKind() === 'confirm') {
            <button mat-stroked-button [disabled]="busy()" (click)="preview()">{{ busy() ? 'Validating…' : 'Validate (dry run)' }}</button>
            <button mat-flat-button color="primary" [disabled]="busy()" (click)="install()">Install</button>
          } @else {
            <button mat-flat-button color="primary" [disabled]="!canNext() || busy()" (click)="next()">Next</button>
          }
        }
      </div>
    </div>
  `,
  styles: [`
    .bm-wz { display: flex; flex-direction: column; height: min(720px, 82vh); }
    .bm-wz-title { font-size: 18px; font-weight: 700; padding: 4px 4px 12px; display: flex; justify-content: space-between; align-items: baseline; }
    .bm-wz-host { font-size: 13px; opacity: 0.6; font-weight: 400; }
    .bm-wz-body { display: grid; grid-template-columns: 210px 1fr; gap: 18px; flex: 1; min-height: 0; }
    .bm-wz-steps { border-right: 1px solid var(--mat-sys-outline-variant); padding-right: 10px; overflow-y: auto; }
    .bm-wz-step { display: flex; align-items: center; gap: 8px; padding: 8px 10px; font-size: 13px; border-left: 3px solid transparent; opacity: 0.6; }
    .bm-wz-step--cur { border-left-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); opacity: 1; font-weight: 600; }
    .bm-wz-step--done { opacity: 0.9; }
    .bm-wz-step-ic { display: inline-flex; align-items: center; justify-content: center; width: 20px; height: 20px; border-radius: 50%; background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); font-size: 11px; }
    .bm-wz-step--done .bm-wz-step-ic { background: color-mix(in srgb, var(--bm-green, #2e7d32) 30%, transparent); }
    .bm-wz-step-ic mat-icon { font-size: 14px; width: 14px; height: 14px; }
    .bm-wz-main { overflow-y: auto; padding: 0 6px; min-width: 0; }
    .bm-wz-main h2 { margin: 4px 0 2px; }
    .bm-wz-lead { opacity: 0.7; margin: 0 0 16px; line-height: 1.5; }
    .bm-wz-search { display: block; width: 100%; max-width: 360px; margin: 0 0 12px; padding: 7px 11px; border-radius: 6px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font-size: 13px; box-sizing: border-box; }
    /* Miller-columns role browser: categories | packages | detail */
    .bm-wz-miller { display: grid; grid-template-columns: 190px 1fr 300px; gap: 12px; height: 440px; }
    .bm-wz-mcol { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow-y: auto; padding: 6px; min-width: 0; }
    .bm-wz-mpad { padding: 10px; }
    .bm-wz-mcat { display: flex; align-items: center; gap: 8px; padding: 7px 9px; border-radius: 6px; cursor: pointer; font-size: 13px; }
    .bm-wz-mcat:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-wz-mcat-ic { font-size: 18px; width: 18px; height: 18px; opacity: 0.75; }
    .bm-wz-mcat-lbl { flex: 1; }
    .bm-wz-mcount { font-size: 11px; opacity: 0.5; font-variant-numeric: tabular-nums; }
    .bm-wz-msel { background: color-mix(in srgb, var(--mat-sys-primary) 14%, transparent); }
    .bm-wz-mrole { display: flex; align-items: flex-start; gap: 8px; padding: 7px 9px; border-radius: 6px; cursor: pointer; }
    .bm-wz-mrole:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-wz-mrole-txt { min-width: 0; flex: 1; }
    .bm-wz-mrole-lbl { font-size: 13px; font-weight: 600; }
    .bm-wz-mrole-desc { font-size: 12px; opacity: 0.62; line-height: 1.4; margin-top: 1px;
      display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
    .bm-wz-role-ic { font-size: 18px; width: 18px; height: 18px; opacity: 0.8; margin-top: 2px; }
    .bm-wz-badge { font-size: 10px; padding: 1px 7px; border-radius: 10px; margin-left: 6px; vertical-align: middle;
      background: color-mix(in srgb, var(--bm-green, #2e7d32) 20%, transparent); }
    .bm-wz-desc { padding: 14px; }
    .bm-wz-prefill { display: flex; align-items: center; gap: 7px; font-size: 13px; margin: -6px 0 14px; padding: 7px 11px; border-radius: 6px;
      background: color-mix(in srgb, var(--bm-green, #2e7d32) 12%, transparent); }
    .bm-wz-prefill mat-icon { font-size: 18px; width: 18px; height: 18px; color: var(--bm-green, #2e7d32); }
    .bm-wz-desc-lbl { font-weight: 700; margin-bottom: 6px; }
    .bm-wz-desc p { opacity: 0.8; line-height: 1.5; margin: 0 0 8px; }
    .bm-wz-desc-pkg { font-size: 12px; opacity: 0.7; }
    .bm-wz-warn { font-size: 12px; margin-top: 8px; padding: 6px 8px; border-radius: 6px; background: color-mix(in srgb, var(--bm-gold, #f9a825) 18%, transparent); }
    .bm-wz-dim { opacity: 0.55; }
    .bm-wz-sum { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 10px 14px; margin-bottom: 10px; }
    .bm-wz-sum-h { font-weight: 600; margin-bottom: 6px; }
    .bm-wz-dl { display: grid; grid-template-columns: auto 1fr; gap: 2px 14px; margin: 0; font-size: 13px; }
    .bm-wz-dl dt { opacity: 0.55; } .bm-wz-dl dd { margin: 0; }
    .bm-mono { font-family: ui-monospace, monospace; font-size: 12px; }
    .bm-wz-dry, .bm-wz-result { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 10px 14px; margin-top: 10px; font-size: 13px; }
    .bm-wz-dry-h, .bm-wz-result-h { font-weight: 600; display: flex; align-items: center; gap: 6px; margin-bottom: 6px; }
    .bm-wz-mon { display: flex; align-items: center; gap: 8px; margin-top: 14px; font-size: 13px; }
    .bm-wz-tpl { margin-top: 14px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 8px 12px; }
    .bm-wz-tpl summary { cursor: pointer; font-weight: 600; font-size: 13px; }
    .bm-wz-tpl-bar { display: flex; align-items: center; gap: 8px; margin: 10px 0; flex-wrap: wrap; }
    .bm-wz-tpl-name { flex: 1; min-width: 160px; padding: 6px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant);
      background: var(--mat-sys-surface); color: inherit; font-size: 13px; }
    .bm-wz-saved { font-size: 12px; color: var(--bm-green, #2e7d32); }
    .bm-wz-nt { background: var(--mat-sys-surface-container-high, rgba(127,127,127,0.12)); border-radius: 6px; padding: 10px 12px;
      font-family: ui-monospace, monospace; font-size: 12px; white-space: pre; overflow-x: auto; margin: 0; max-height: 320px; overflow-y: auto; }
    .bm-wz-stepr { display: flex; align-items: center; gap: 6px; font-size: 12.5px; padding: 1px 0; }
    .bm-wz-stepr-s { opacity: 0.55; margin-left: auto; }
    .bm-wz-err { color: var(--bm-red, #c62828); font-size: 12px; font-family: ui-monospace, monospace; white-space: pre-wrap; margin: 2px 0 6px 22px; }
    .bm-ok { color: var(--bm-green, #2e7d32); font-size: 16px; width: 16px; height: 16px; }
    .bm-err { color: var(--bm-red, #c62828); font-size: 16px; width: 16px; height: 16px; }
    .bm-wz-footer { display: flex; align-items: center; gap: 8px; padding-top: 12px; border-top: 1px solid var(--mat-sys-outline-variant); }
    .bm-wz-spacer { flex: 1; }
  `],
})
export class AddRolesWizardComponent {
  private wizard = inject(WizardService);
  private checkService = inject(CheckService);
  private agents = inject(AgentService);
  private dialogRef = inject(MatDialogRef<AddRolesWizardComponent>);
  setupMonitoring = signal(true);
  activeCat = signal<string>('');
  /** Host's current on-host config (per file) — for pre-filling installed roles. */
  private observed = signal<ObservedResource[]>([]);

  step = signal(0);
  focus = signal<string>('');
  picked = signal<Set<string>>(new Set());
  busy = signal(false);
  finished = signal(false);
  dryRun = signal<RunState[] | null>(null);
  runStates = signal<RunState[]>([]);
  private runbooks = signal<Record<string, WizardRunbook>>({});
  private values = signal<Record<string, Record<string, unknown>>>({});
  forms = viewChildren(ParamFormComponent);

  constructor(@Inject(MAT_DIALOG_DATA) public data: AddRolesWizardData) {
    // Read the host's current config once (gpedit-style): lets Configure show
    // the existing on-host settings for already-installed roles. Best-effort.
    this.agents.observedState(data.agentId).subscribe({
      next: (r) => this.observed.set(r.observed?.config ?? []),
      error: () => {},
    });
    if (data.preselect) {
      this.picked.set(new Set([data.preselect]));
      this.loadRunbooks([data.preselect]);
      this.step.set(2); // jump to first Configure step
    }
  }

  // ---- step model ----
  // An installed package is normally excluded (nothing to install) — EXCEPT the
  // preselect ("Configure" on an installed role): its runbook re-runs install
  // (idempotent noop) + config render + service restart.
  toInstall = computed(() => [...this.picked()].filter((p) => !this.isInstalled(p) || p === this.data.preselect));
  private cfgPkgs = computed(() => this.toInstall().filter((p) => this.data.catalog[p]?.template));
  stepLabels = computed(() => [
    'Before you begin', 'Select roles',
    ...this.cfgPkgs().map((p) => `Configure ${this.catLabel(p)}`),
    'Confirmation', 'Results',
  ]);
  stepKind = computed<'before' | 'select' | 'cfg' | 'confirm' | 'results'>(() => {
    const i = this.step();
    if (i === 0) return 'before';
    if (i === 1) return 'select';
    const cfgs = this.cfgPkgs();
    if (i >= 2 && i < 2 + cfgs.length) return 'cfg';
    if (i === 2 + cfgs.length) return 'confirm';
    return 'results';
  });
  cfgPkg = computed(() => this.cfgPkgs()[this.step() - 2] ?? '');
  cfgLabel = computed(() => this.catLabel(this.cfgPkg()));

  roleQuery = signal('');
  grouped = computed(() => {
    const q = this.roleQuery().trim().toLowerCase();
    const groups = new Map<string, (CatalogPackage & { name: string })[]>();
    for (const [name, entry] of Object.entries(this.data.catalog)) {
      if (entry.kind === 'config') continue; // base-system files aren't installable roles
      if (q && !name.toLowerCase().includes(q) && !entry.label.toLowerCase().includes(q)
          && !(entry.description || '').toLowerCase().includes(q)) continue;
      const cat = entry.category || 'other';
      (groups.get(cat) ?? groups.set(cat, []).get(cat)!).push({ ...entry, name });
    }
    return [...groups.entries()].map(([category, items]) => ({ category, items: items.sort((a, b) => a.label.localeCompare(b.label)) }));
  });
  focused = computed(() => { const n = this.focus(); const e = this.data.catalog[n]; return e ? { ...e, name: n } : null; });

  // Miller column 1: categories in a defined order (grouped() is already query-filtered).
  catsOrdered = computed(() =>
    [...this.grouped()].sort((a, b) => {
      const ia = CAT_ORDER.indexOf(a.category), ib = CAT_ORDER.indexOf(b.category);
      return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib) || a.category.localeCompare(b.category);
    }),
  );
  /** The selected category, falling back to the first when the current one is
   * filtered away (or nothing picked yet). */
  effectiveCat = computed(() => {
    const cats = this.catsOrdered();
    const cur = this.activeCat();
    return cats.some((c) => c.category === cur) ? cur : (cats[0]?.category ?? '');
  });
  // Miller column 2: packages in the active category.
  catItems = computed(() => this.catsOrdered().find((c) => c.category === this.effectiveCat())?.items ?? []);
  catIcon(c: string): string { return CAT_META[c]?.icon ?? 'folder'; }
  catName(c: string): string { return CAT_META[c]?.label ?? (c.charAt(0).toUpperCase() + c.slice(1)); }

  catLabel(p: string): string { return this.data.catalog[p]?.label ?? p; }
  isInstalled(p: string): boolean { return p in this.data.context.installed; }
  resolvedPackages(p: string): string { return (this.data.context.catalog_resolved[p]?.packages || []).join(', '); }
  rb(p: string): WizardRunbook | undefined { return this.runbooks()[p]; }

  toggle(name: string): void {
    const s = new Set(this.picked());
    s.has(name) ? s.delete(name) : s.add(name);
    this.picked.set(s);
  }
  canNext(): boolean { return this.stepKind() !== 'select' || this.toInstall().length > 0; }

  /** Prefill a Configure form. For an already-installed role we merge the host's
   * CURRENT on-host config (read via state/observed, matched by config_path) over
   * the schema defaults — gpedit-style. Fresh installs have no observed file at
   * that path, so they fall back to defaults. */
  initialFor(pkg: string): Record<string, unknown> {
    const res = this.data.context.catalog_resolved[pkg];
    const base = { _packages: res?.packages ?? [], _dest: res?.config_path ?? '', _service: res?.service ?? '' };
    const cur = this.currentValues(pkg);
    return cur ? { ...base, ...cur } : base;
  }

  /** The host's current parsed config values for this role's config file, or
   * null if the file isn't present/parsed on the host yet. */
  private currentValues(pkg: string): Record<string, unknown> | null {
    const path = this.data.context.catalog_resolved[pkg]?.config_path;
    if (!path) return null;
    const obs = this.observed().find((o) => o.path === path && o.values && Object.keys(o.values).length > 0);
    return obs?.values ?? null;
  }
  prefilled(pkg: string): boolean { return this.currentValues(pkg) !== null; }
  setValues(pkg: string, v: Record<string, unknown>): void {
    this.values.update((m) => ({ ...m, [pkg]: v }));
  }

  private loadRunbooks(pkgs: string[]): void {
    for (const p of pkgs) {
      if (this.runbooks()[p] || !this.data.catalog[p]?.template) continue;
      this.wizard.runbookByName(`install-${p}`).subscribe((rb) => {
        if (rb) this.runbooks.update((m) => ({ ...m, [p]: rb }));
      });
    }
  }

  next(): void {
    if (this.stepKind() === 'select') this.loadRunbooks(this.cfgPkgs());
    this.step.update((i) => i + 1);
  }
  prev(): void { this.step.update((i) => Math.max(0, i - 1)); }

  /** Merge form values + family runtime vars for a package's run. */
  private varsFor(pkg: string): Record<string, unknown> {
    const res = this.data.context.catalog_resolved[pkg] || {};
    return {
      ...(this.values()[pkg] || {}),
      _packages: res.packages ?? [], _dest: res.config_path ?? '', _service: res.service ?? '',
    };
  }

  // --- Wizard = runbook: show the composed runbook + save it as a template ---
  templateName = signal('');
  savedMsg = signal('');

  /** The wizard as a plaintext runbook: one `runbook:` role call per selected
   * package, carrying the configured variables — exactly what runs, editable
   * later in the Workflow editor. This IS the template you save. */
  templateNt(): string {
    const pkgs = this.toInstall();
    const lines = [`name: ${this.templateName().trim() || 'install ' + pkgs.join(' ')}`, `targets: host:${this.data.hostName}`, 'steps:'];
    for (const p of pkgs) {
      lines.push('    -');
      lines.push(`        name: ${this.catLabel(p)}`);
      lines.push(`        runbook: install-${p}`);
      const vars = this.values()[p] || {};
      const keys = Object.keys(vars).filter((k) => !k.startsWith('_') && vars[k] !== undefined && vars[k] !== '');
      if (keys.length) {
        lines.push('        vars:');
        for (const k of keys) lines.push(...this.ntValue(k, vars[k], 12));
      }
    }
    return lines.join('\n') + '\n';
  }

  /** Serialise one variable to NestedText at the given indent (scalars inline,
   * lists as `- item`, dicts nested). */
  private ntValue(key: string, v: unknown, indent: number): string[] {
    const pad = ' '.repeat(indent);
    if (Array.isArray(v)) {
      if (!v.length) return [`${pad}${key}: []`];
      const out = [`${pad}${key}:`];
      for (const el of v) {
        if (el !== null && typeof el === 'object') {
          out.push(`${pad}    -`);
          for (const [ek, ev] of Object.entries(el)) out.push(...this.ntValue(ek, ev, indent + 8));
        } else {
          out.push(`${pad}    - ${el}`);
        }
      }
      return out;
    }
    if (v !== null && typeof v === 'object') {
      const out = [`${pad}${key}:`];
      for (const [ek, ev] of Object.entries(v as Record<string, unknown>)) out.push(...this.ntValue(ek, ev, indent + 4));
      return out;
    }
    return [`${pad}${key}: ${v}`];
  }

  copyTemplate(): void {
    navigator.clipboard?.writeText(this.templateNt()).then(
      () => { this.savedMsg.set('Copied to clipboard'); setTimeout(() => this.savedMsg.set(''), 2500); },
      () => {},
    );
  }

  saveAsTemplate(): void {
    this.savedMsg.set('');
    this.wizard.saveRunbook(this.templateNt(), 'templates').subscribe({
      next: (r) => this.savedMsg.set(`Saved as template "${r.name}" — editable in the Workflow designer`),
      error: (e: { error?: { detail?: string } }) => this.savedMsg.set(e?.error?.detail || 'save failed (name may already exist)'),
    });
  }

  /** After a successful install, set up a monitoring check for each role,
   * auto-configured from the role's own variables — a generic service_health
   * check (systemd unit active + enabled) whose `unit` comes straight from the
   * role's resolved service. Richer network checks (http/tcp/dns) can be added
   * per host via the Service checks snap-in. */
  private assignMonitoring(states: RunState[]): void {
    for (const rs of states) {
      if (rs.error || rs.result?.ok === false || rs.result?.aborted) continue;
      const unit = (this.data.context.catalog_resolved[rs.pkg] || {}).service || '';
      if (!unit) continue;
      this.checkService.createAssignment({
        check_name: 'service_health', scope_type: 'host', agent_id: this.data.agentId,
        parameters: { service_name: `${this.catLabel(rs.pkg)} health`, unit, require_enabled: true },
        source: 'wizard',
      }).subscribe({ next: () => {}, error: () => {} });
    }
  }

  preview(): void { this.execute(true); }
  install(): void { this.step.set(this.stepLabels().length - 1); this.execute(false); }

  private execute(dry: boolean): void {
    const pkgs = this.toInstall();
    this.busy.set(true);
    if (!dry) this.runStates.set(pkgs.map((p) => ({ pkg: p, running: true })));
    this.loadRunbooks(pkgs);
    // SEQUENTIAL on purpose: two apt/dnf runs on the same host would fight over
    // the package-manager lock. Each package's result is surfaced as it lands.
    from(pkgs).pipe(
      concatMap((p) => {
        const r = this.runbooks()[p];
        if (!r) return of<RunState>({ pkg: p, error: 'no install runbook (template missing)' });
        return this.wizard.run(this.data.agentId, r.nt, this.varsFor(p), dry).pipe(
          map((resp): RunState => ({ pkg: p, result: resp })),
          catchError((e: { error?: { detail?: string } }) => of<RunState>({ pkg: p, error: e?.error?.detail || 'run failed' })),
        );
      }),
      map((state) => {
        if (!dry) this.runStates.update((all) => all.map((s) => (s.pkg === state.pkg ? state : s)));
        return state;
      }),
      toArray(),
    ).subscribe((states) => {
      this.busy.set(false);
      if (dry) this.dryRun.set(states);
      else {
        this.runStates.set(states);
        this.finished.set(true);
        if (this.setupMonitoring()) this.assignMonitoring(states);
      }
    });
  }

  summarize(rs: RunState): string {
    if (rs.error) return rs.error;
    const steps = rs.result?.steps || [];
    const changed = steps.filter((s) => s.status === 'changed').length;
    const failed = steps.filter((s) => s.status === 'failed').length;
    return failed ? `${failed} step(s) would fail` : `${steps.length} step(s), ${changed} change(s)`;
  }

  close(): void { this.dialogRef.close(this.finished()); }
}
