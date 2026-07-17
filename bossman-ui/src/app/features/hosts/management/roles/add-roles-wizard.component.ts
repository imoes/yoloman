import { Component, Inject, computed, inject, signal, viewChildren } from '@angular/core';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { forkJoin, of, catchError, map } from 'rxjs';
import { CatalogPackage } from '../../../../core/services/package-catalog.service';
import { WizardContext, WizardRunbook, WizardService, RunbookRunResult } from '../../../../core/services/wizard.service';
import { ParamFormComponent } from '../../../../shared/param-form/param-form.component';

export interface AddRolesWizardData {
  agentId: string;
  hostName: string;
  catalog: Record<string, CatalogPackage>;
  context: WizardContext;
  preselect?: string; // jump straight to configuring one already-installed package
}

interface RunState { pkg: string; result?: RunbookRunResult; error?: string; running?: boolean; }

/** "Add Roles and Features" — Windows-Server-Manager-style install wizard.
 * Before You Begin → Select Roles → Configure each → Confirmation → Results.
 * Installs packages and renders their config via the seeded install-<pkg>
 * runbooks, entirely inside the management console. */
@Component({
  selector: 'app-add-roles-wizard',
  standalone: true,
  imports: [MatDialogModule, MatButtonModule, MatIconModule, MatCheckboxModule, MatProgressSpinnerModule, ParamFormComponent],
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
              <p class="bm-wz-lead">Pick the roles to install on this host.</p>
              <div class="bm-wz-select">
                <div class="bm-wz-roles">
                  @for (grp of grouped(); track grp.category) {
                    <div class="bm-wz-cat">{{ grp.category }}</div>
                    @for (r of grp.items; track r.name) {
                      <label class="bm-wz-role" [class.bm-wz-role--focus]="focus() === r.name" (mouseenter)="focus.set(r.name)">
                        <mat-checkbox [checked]="picked().has(r.name)" [disabled]="isInstalled(r.name)" (change)="toggle(r.name)" />
                        <mat-icon class="bm-wz-role-ic">{{ r.icon }}</mat-icon>
                        <span class="bm-wz-role-lbl">{{ r.label }}</span>
                        @if (isInstalled(r.name)) { <span class="bm-wz-badge">Installed</span> }
                      </label>
                    }
                  }
                </div>
                <aside class="bm-wz-desc">
                  @if (focused(); as r) {
                    <div class="bm-wz-desc-lbl">{{ r.label }}</div>
                    <p>{{ r.description }}</p>
                    <div class="bm-wz-desc-pkg">Package: <code>{{ resolvedPackages(r.name) }}</code></div>
                    @if (!r.template) { <div class="bm-wz-warn">No configuration template yet — installs with defaults, no Configure step.</div> }
                  } @else { <p class="bm-wz-dim">Hover a role to see what it does.</p> }
                </aside>
              </div>
            }
            @case ('cfg') {
              <h2>Configure {{ cfgLabel() }}</h2>
              <p class="bm-wz-lead">Set the configuration for {{ cfgLabel() }}. Defaults are shown for every setting.</p>
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
    .bm-wz-select { display: grid; grid-template-columns: 1fr 320px; gap: 16px; }
    .bm-wz-cat { font-size: 11px; text-transform: uppercase; opacity: 0.55; margin: 12px 0 4px; }
    .bm-wz-role { display: flex; align-items: center; gap: 8px; padding: 5px 8px; border-radius: 6px; cursor: pointer; }
    .bm-wz-role--focus { background: color-mix(in srgb, var(--mat-sys-primary) 8%, transparent); }
    .bm-wz-role-ic { font-size: 18px; width: 18px; height: 18px; opacity: 0.8; }
    .bm-wz-role-lbl { flex: 1; }
    .bm-wz-badge { font-size: 11px; padding: 1px 8px; border-radius: 10px; background: color-mix(in srgb, var(--bm-green, #2e7d32) 20%, transparent); }
    .bm-wz-desc { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 14px; align-self: start; }
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
  private dialogRef = inject(MatDialogRef<AddRolesWizardComponent>);

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
    if (data.preselect) {
      this.picked.set(new Set([data.preselect]));
      this.loadRunbooks([data.preselect]);
      this.step.set(2); // jump to first Configure step
    }
  }

  // ---- step model ----
  toInstall = computed(() => [...this.picked()].filter((p) => !this.isInstalled(p)));
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

  grouped = computed(() => {
    const groups = new Map<string, (CatalogPackage & { name: string })[]>();
    for (const [name, entry] of Object.entries(this.data.catalog)) {
      const cat = entry.category || 'other';
      (groups.get(cat) ?? groups.set(cat, []).get(cat)!).push({ ...entry, name });
    }
    return [...groups.entries()].map(([category, items]) => ({ category, items: items.sort((a, b) => a.label.localeCompare(b.label)) }));
  });
  focused = computed(() => { const n = this.focus(); const e = this.data.catalog[n]; return e ? { ...e, name: n } : null; });

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

  /** Prefill a Configure form: installed → schema default (handled by ParamForm). */
  initialFor(pkg: string): Record<string, unknown> {
    const res = this.data.context.catalog_resolved[pkg];
    return { _packages: res?.packages ?? [], _dest: res?.config_path ?? '', _service: res?.service ?? '' };
  }
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

  preview(): void { this.execute(true); }
  install(): void { this.step.set(this.stepLabels().length - 1); this.execute(false); }

  private execute(dry: boolean): void {
    const pkgs = this.toInstall();
    this.busy.set(true);
    if (!dry) this.runStates.set(pkgs.map((p) => ({ pkg: p, running: true })));
    this.loadRunbooks(pkgs);
    forkJoin(pkgs.map((p) => {
      const r = this.runbooks()[p];
      if (!r) return of<RunState>({ pkg: p, error: 'no install runbook (template missing)' });
      return this.wizard.run(this.data.agentId, r.nt, this.varsFor(p), dry).pipe(
        map((resp): RunState => ({ pkg: p, result: resp.result })),
        catchError((e: { error?: { detail?: string } }) => of<RunState>({ pkg: p, error: e?.error?.detail || 'run failed' })),
      );
    })).subscribe((states) => {
      this.busy.set(false);
      if (dry) this.dryRun.set(states);
      else { this.runStates.set(states); this.finished.set(true); }
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
