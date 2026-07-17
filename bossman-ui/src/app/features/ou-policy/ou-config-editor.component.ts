import { Component, OnChanges, SimpleChanges, Input, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AgentService } from '../../core/services/agent.service';
import { OuService } from '../../core/services/ou.service';
import { HostGroupService } from '../../core/services/host-group.service';
import { DialogService } from '../../shared/dialogs/dialog.service';
import { DirectiveSpec, ObservedResource } from '../../core/models/agent.model';
import { ConfigCategory, groupByCategory } from '../../shared/config-categories';

interface ScopePolicy {
  id: string;
  path: string;
  type: string;
  format: string | null;
  separator: string | null;
  values: Record<string, unknown>;
  template: string | null;
}

interface SettingRow {
  key: string;
  state: 'Configured' | 'Removed' | 'Not configured';
  policy: string;
  live: string;
}

/** What the gpedit editor is scoped to — an OU or a host group. For a group
 * the catalog host is resolved from its member agent ids (an OU resolves it
 * from its subtree members endpoint). */
export interface EditorScope {
  kind: 'ou' | 'group';
  id: string;
  label: string;
  memberAgentIds?: string[];
}

/** The full gpedit editor ON the Policy console (Block K5): select an OU and
 * author config-value policies for it right there — the Windows model, where
 * policies live at scope and a host only shows the resolved result. The
 * settings CATALOG (which files/keys exist) comes from the first reachable
 * member host of the OU's subtree ("Host A = Host B" — any member is a valid
 * template of the others); the policy VALUES come from this scope's
 * ConfigPolicy rows. Files are grouped by semantic category and a live search
 * filters across every category by file path or setting key. */
@Component({
  selector: 'app-ou-config-editor',
  standalone: true,
  imports: [FormsModule, MatIconModule, MatButtonModule],
  template: `
    <div class="bm-oce">
      <h3 class="bm-oce-h">Settings (gpedit)</h3>
      @if (catalogHost(); as ch) {
        <p class="bm-oce-src">Policies set here apply down to every host under this {{ scopeWord }}. The available settings are read from a member host (<strong>{{ ch }}</strong>) as a reference.</p>
      } @else if (loaded()) {
        <p class="bm-oce-src">Policies set here apply down to every host under this {{ scopeWord }}. No reachable member host — showing only settings that already have a policy.</p>
      }
      <input class="bm-oce-search" type="search" placeholder="Search settings…" [ngModel]="search()" (ngModelChange)="search.set($event)" />
      <div class="bm-oce-panes">
        <!-- Miller column 1: categories -->
        <div class="bm-oce-col">
          @for (grp of groups(); track grp.cat.key) {
            <div class="bm-oce-cat" [class.bm-oce-sel]="activeCat() === grp.cat.key" (click)="selectCat(grp.cat.key)">
              <mat-icon class="bm-oce-cat-ic">{{ grp.cat.icon }}</mat-icon>{{ grp.cat.label }}
              <span class="bm-oce-count">{{ grp.files.length }}</span>
            </div>
          } @empty {
            <p class="bm-oce-empty">{{ loaded() ? 'Nothing matches.' : 'Loading…' }}</p>
          }
        </div>
        <!-- Miller column 2: files in the active category -->
        <div class="bm-oce-col">
          @for (f of filesInActiveCat(); track f.path) {
            <div class="bm-oce-file" [class.bm-oce-sel]="selected() === f.path" (click)="select(f.path)" [title]="f.path">
              {{ baseName(f.path) }}
              @if (policyFor(f.path)) { <span class="bm-oce-dot" title="policy at this scope">●</span> }
            </div>
          } @empty {
            <p class="bm-oce-empty">{{ activeCat() ? 'No files.' : 'Pick a category.' }}</p>
          }
        </div>
        <!-- Miller column 3: the file's settings -->
        <div class="bm-oce-main">
          @if (selected(); as sel) {
            <h4 class="bm-oce-file-h">{{ sel }}</h4>
            <table class="bm-oce-settings">
              <thead><tr><th>Setting</th><th>State</th><th>Policy value</th><th>Live example</th></tr></thead>
              <tbody>
                @for (row of rows(); track row.key) {
                  <tr (click)="openRow(row)" [class.bm-oce-row-sel]="editKey() === row.key" [class.bm-oce-managed]="row.state !== 'Not configured'">
                    <td class="bm-oce-key">{{ row.key }}</td>
                    <td>{{ row.state }}</td>
                    <td>{{ row.state === 'Configured' ? row.policy : row.state === 'Removed' ? '(absent)' : '' }}</td>
                    <td class="bm-oce-live">{{ row.live }}</td>
                  </tr>
                } @empty {
                  <tr><td colspan="4" class="bm-oce-empty">No settings known for this file yet.</td></tr>
                }
              </tbody>
            </table>
            @if (editKey(); as ek) {
              <div class="bm-oce-editor">
                <strong>{{ ek }}</strong>
                @if (directiveSpec(); as ds) {
                  @if (ds.description) { <p class="bm-oce-src">{{ ds.description }}@if (ds.default) { <span> · default: <code>{{ ds.default }}</code></span> }</p> }
                }
                <label class="bm-oce-radio"><input type="radio" name="ocemode" [checked]="mode() === 'notconf'" (change)="mode.set('notconf')" /> Not configured — no policy at this {{ scopeWord }}</label>
                <label class="bm-oce-radio"><input type="radio" name="ocemode" [checked]="mode() === 'configured'" (change)="mode.set('configured')" /> Configured</label>
                @if (mode() === 'configured') {
                  @if (valueOptions(); as opts) {
                    <select class="bm-oce-val" [ngModel]="value()" (ngModelChange)="value.set($event)">
                      @for (o of opts; track o) { <option [value]="o">{{ o }}</option> }
                    </select>
                  } @else {
                    <input class="bm-oce-val" [ngModel]="value()" (ngModelChange)="value.set($event)" list="bm-oce-suggest" />
                    <datalist id="bm-oce-suggest">
                      @for (v of suggestions(); track v) { <option [value]="v"></option> }
                    </datalist>
                  }
                }
                <label class="bm-oce-radio"><input type="radio" name="ocemode" [checked]="mode() === 'removed'" (change)="mode.set('removed')" /> Removed — enforce the key's absence</label>
                @if (error(); as e) { <p class="bm-oce-err">{{ e }}</p> }
                <div class="bm-oce-actions">
                  <button mat-button (click)="closeRow()" [disabled]="busy()">Cancel</button>
                  <button mat-flat-button color="primary" (click)="apply()" [disabled]="busy()">Apply to {{ scopeWord }}</button>
                </div>
              </div>
            }
            <div class="bm-oce-add">
              <input class="bm-oce-val" placeholder="Add a setting key…" [ngModel]="newKey()" (ngModelChange)="newKey.set($event)" />
              <button mat-stroked-button (click)="addKey()" [disabled]="!newKey().trim()">Add</button>
            </div>
          } @else {
            <p class="bm-oce-empty">Select a config file.</p>
          }
        </div>
      </div>
    </div>
  `,
  styles: [
    `
      .bm-oce { margin-top: 18px; }
      .bm-oce-h { margin: 0 0 4px; }
      .bm-oce-src { font-size: 12px; opacity: 0.65; margin: 0 0 10px; }
      /* Wrap so the settings table drops below the two Miller columns in a
         narrow panel (the OU detail panel) instead of overflowing to the right;
         stays side-by-side when there's room (like the host gpedit). */
      .bm-oce-panes { display: flex; flex-wrap: wrap; gap: 10px; align-items: flex-start; }
      .bm-oce-col { flex: 0 0 190px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 5px 0; font-size: 13px; max-height: 480px; overflow-y: auto; }
      .bm-oce-search { display: block; width: 100%; max-width: 420px; margin: 2px 0 10px; padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font-size: 13px; box-sizing: border-box; }
      .bm-oce-cat { padding: 7px 10px; cursor: pointer; display: flex; align-items: center; gap: 6px; border-left: 3px solid transparent; }
      .bm-oce-cat:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
      .bm-oce-cat .bm-oce-count { margin-left: auto; font-size: 11px; opacity: 0.5; }
      .bm-oce-cat-ic { font-size: 16px; width: 16px; height: 16px; opacity: 0.8; }
      .bm-oce-file { padding: 6px 10px; cursor: pointer; border-left: 3px solid transparent; display: flex; align-items: center; gap: 6px; }
      .bm-oce-file:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
      .bm-oce-sel { border-left-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
      .bm-oce-dot { color: var(--mat-sys-primary); font-size: 10px; }
      .bm-oce-main { flex: 1 1 360px; min-width: 0; overflow-x: auto; }
      .bm-oce-live { max-width: 220px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .bm-oce-file-h { margin: 0 0 8px; font-family: ui-monospace, monospace; font-size: 14px; }
      .bm-oce-settings { width: 100%; border-collapse: collapse; font-size: 13px; }
      .bm-oce-settings th { text-align: left; font-size: 11px; opacity: 0.65; padding: 6px 10px; }
      .bm-oce-settings td { padding: 6px 10px; border-top: 1px solid var(--mat-sys-outline-variant); cursor: pointer; }
      .bm-oce-managed td { font-weight: 600; }
      .bm-oce-row-sel td { background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
      .bm-oce-key { font-family: ui-monospace, monospace; }
      .bm-oce-live { opacity: 0.6; }
      .bm-oce-editor { margin-top: 12px; padding: 12px 14px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; display: flex; flex-direction: column; gap: 8px; }
      .bm-oce-radio { display: flex; align-items: center; gap: 8px; font-size: 13px; cursor: pointer; }
      .bm-oce-val { padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font-size: 13px; }
      .bm-oce-actions { display: flex; justify-content: flex-end; gap: 8px; }
      .bm-oce-add { margin-top: 10px; display: flex; gap: 8px; }
      .bm-oce-empty { opacity: 0.6; font-size: 13px; padding: 8px 10px; }
      .bm-oce-err { color: var(--mat-sys-error); font-size: 13px; margin: 0; }
    `,
  ],
})
export class OuConfigEditorComponent implements OnChanges {
  @Input({ required: true }) scope!: EditorScope;

  private agentService = inject(AgentService);
  private ouService = inject(OuService);
  private hostGroupService = inject(HostGroupService);
  private appDialog = inject(DialogService);

  get scopeWord(): string { return this.scope.kind === 'group' ? 'group' : 'OU'; }
  private listArg() { return this.scope.kind === 'ou' ? { ouId: this.scope.id } : { groupId: this.scope.id }; }
  private scopeArg() { return this.scope.kind === 'ou' ? { scope_ou_id: this.scope.id } : { host_group_id: this.scope.id }; }

  loaded = signal(false);
  catalogHost = signal<string | null>(null);
  // ADMX per-directive value catalog (parity with the host gpedit) — loaded once.
  directiveCatalog = signal<Record<string, Record<string, DirectiveSpec>>>({});
  private catalog = signal<ObservedResource[]>([]);
  private policies = signal<ScopePolicy[]>([]);
  search = signal('');
  activeCat = signal<string | null>(null);
  selected = signal<string | null>(null);
  editKey = signal<string | null>(null);
  mode = signal<'notconf' | 'configured' | 'removed'>('configured');
  value = signal('');
  newKey = signal('');
  busy = signal(false);
  error = signal<string | null>(null);

  ngOnChanges(changes: SimpleChanges): void {
    if (changes['scope']) this.reload();
  }

  private reload(): void {
    this.loaded.set(false);
    this.catalog.set([]);
    this.policies.set([]);
    this.selected.set(null);
    this.editKey.set(null);
    this.catalogHost.set(null);
    this.ouService.listConfigPolicies(this.listArg()).subscribe((ps) => this.policies.set(ps));
    if (!Object.keys(this.directiveCatalog()).length) {
      this.agentService.configDirectives().subscribe({ next: (r) => this.directiveCatalog.set(r.directives || {}), error: () => {} });
    }
    // Resolve a reachable member as the settings catalog host: an OU asks its
    // subtree members endpoint; a group uses its own member agent ids.
    const useCatalog = (host: { id: string; name: string } | null) => {
      if (!host) { this.loaded.set(true); return; }
      this.agentService.observedState(host.id).subscribe({
        next: (res) => {
          this.catalog.set((res.observed?.config ?? []).filter((r) => !r.error && r.values));
          this.catalogHost.set(host.name);
          this.loaded.set(true);
        },
        error: () => this.loaded.set(true),
      });
    };
    if (this.scope.kind === 'ou') {
      this.ouService.members(this.scope.id).subscribe({
        next: (members) => useCatalog(members.find((m) => m.address) ?? null),
        error: () => this.loaded.set(true),
      });
    } else {
      // Group: resolve member agent ids (given, or looked up), then use the
      // first reachable member as the catalog host.
      const pick = (ids: Set<string>) => {
        this.agentService.list().subscribe({
          next: (agents) => useCatalog(agents.find((a) => ids.has(a.id) && a.address) ?? null),
          error: () => this.loaded.set(true),
        });
      };
      if (this.scope.memberAgentIds?.length) {
        pick(new Set(this.scope.memberAgentIds));
      } else {
        this.hostGroupService.list().subscribe({
          next: (groups) => pick(new Set(groups.find((g) => g.id === this.scope.id)?.member_agent_ids ?? [])),
          error: () => this.loaded.set(true),
        });
      }
    }
  }

  /** Catalog files ∪ policy-only paths, category-grouped, search-filtered by
   * path or any setting key inside (mirrors the host gpedit's live search). */
  groups(): { cat: ConfigCategory; files: { path: string }[] }[] {
    const paths = new Map<string, ObservedResource | null>();
    for (const r of this.catalog()) paths.set(r.path, r);
    for (const p of this.policies()) if (!paths.has(p.path)) paths.set(p.path, null);
    const q = this.search().trim().toLowerCase();
    const items = [...paths.entries()]
      .filter(([path, res]) => {
        if (!q) return true;
        if (path.toLowerCase().includes(q)) return true;
        const keys = [
          ...(res ? this.flatKeys(res.values ?? {}, res.format) : []),
          ...this.policyKeys(path),
        ];
        return keys.some((k) => k.toLowerCase().includes(q));
      })
      .map(([path]) => ({ path }));
    return groupByCategory(items);
  }

  /** Miller-column navigation: category → its files → the file's settings.
   * The active category defaults to the first available and follows the
   * search (if the active one filters out, fall back to the first). */
  selectCat(key: string): void {
    this.activeCat.set(key);
    this.selected.set(null);
    this.editKey.set(null);
  }

  filesInActiveCat(): { path: string }[] {
    const gs = this.groups();
    if (!gs.length) return [];
    let active = gs.find((g) => g.cat.key === this.activeCat());
    if (!active) { active = gs[0]; }
    return active.files;
  }

  select(path: string): void {
    this.selected.set(path);
    this.editKey.set(null);
  }

  policyFor(path: string): ScopePolicy | undefined {
    return this.policies().find((p) => p.path === path);
  }

  rows(): SettingRow[] {
    const path = this.selected();
    if (!path) return [];
    const res = this.catalog().find((r) => r.path === path) ?? null;
    const fmt = res?.format ?? this.policyFor(path)?.format ?? 'keyvalue';
    const live = new Map(res ? this.flat(res.values ?? {}, fmt) : []);
    const des = new Map(this.flat(this.policyFor(path)?.values ?? {}, fmt));
    const keys = [...new Set([...live.keys(), ...des.keys()])].sort();
    const q = this.search().trim().toLowerCase();
    const all = keys.map((key): SettingRow => {
      const managed = des.has(key);
      const dv = des.get(key);
      return {
        key,
        state: managed ? (dv === null ? 'Removed' : 'Configured') : 'Not configured',
        policy: dv === null || dv === undefined ? '' : this.scalar(dv),
        live: live.has(key) ? this.scalar(live.get(key)) : '',
      };
    });
    if (!q || path.toLowerCase().includes(q)) return all;
    const hit = all.filter((r) => r.key.toLowerCase().includes(q));
    return hit.length ? hit : all;
  }

  openRow(row: SettingRow): void {
    this.editKey.set(row.key);
    this.mode.set(row.state === 'Removed' ? 'removed' : row.state === 'Configured' ? 'configured' : 'configured');
    this.value.set(row.policy || row.live || '');
    this.error.set(null);
  }
  closeRow(): void {
    this.editKey.set(null);
  }

  addKey(): void {
    const k = this.newKey().trim();
    if (!k) return;
    this.newKey.set('');
    this.openRow({ key: k, state: 'Not configured', policy: '', live: '' });
  }

  /** ADMX spec for the setting being edited (by file basename + key). */
  directiveSpec(): DirectiveSpec | null {
    const path = this.selected(), key = this.editKey();
    if (!path || !key) return null;
    const file = path.split('/').pop() || '';
    return this.directiveCatalog()[file]?.[key] ?? null;
  }

  /** Enum/bool → real allowed values from the ADMX catalog (a listbox), like
   * the host gpedit; falls back to the yes/no-family guess, else free text. */
  valueOptions(): string[] | null {
    const spec = this.directiveSpec();
    if (spec) {
      if (spec.type === 'enum' && spec.values?.length) {
        const v = this.value();
        return spec.values.includes(v) || !v ? spec.values : [v, ...spec.values];
      }
      if (spec.type === 'bool') return ['yes', 'no'];
      if (spec.type === 'int' || spec.type === 'string' || spec.type === 'list') return null;
    }
    const cur = this.value().trim().toLowerCase();
    const families = [['yes', 'no'], ['true', 'false'], ['on', 'off'], ['enabled', 'disabled']];
    return families.find((f) => f.includes(cur)) ?? null;
  }

  suggestions(): string[] {
    const cur = this.value().trim().toLowerCase();
    const families = [['yes', 'no'], ['true', 'false'], ['on', 'off'], ['enabled', 'disabled']];
    return families.find((f) => f.includes(cur)) ?? families.flat();
  }

  apply(): void {
    const path = this.selected();
    const key = this.editKey();
    if (!path || !key) return;
    const fmt = this.catalog().find((r) => r.path === path)?.format ?? this.policyFor(path)?.format ?? 'keyvalue';
    this.busy.set(true);
    this.error.set(null);
    const done = () => {
      this.busy.set(false);
      this.editKey.set(null);
      this.ouService.listConfigPolicies(this.listArg()).subscribe((ps) => this.policies.set(ps));
    };
    const fail = (e: { error?: { detail?: string } }) => {
      this.error.set(e?.error?.detail ?? 'failed');
      this.busy.set(false);
    };
    if (this.mode() === 'notconf') {
      if (!this.policyFor(path)) { done(); return; }
      this.ouService.unsetConfigPolicyKey({ ...this.scopeArg(), path, key }).subscribe({ next: done, error: fail });
      return;
    }
    const value = this.mode() === 'removed' ? null : this.value();
    const values = this.unflatten(key, value, fmt !== 'keyvalue');
    this.ouService.createConfigPolicy({ ...this.scopeArg(), path, format: fmt ?? 'keyvalue', values }).subscribe({
      next: (r) => {
        this.appDialog.notify(
          r.applied_hosts.length ? `Applied to ${r.applied_hosts.length} host(s).` : 'Policy saved (no reachable member yet).',
          'info',
        );
        done();
      },
      error: fail,
    });
  }

  baseName(p: string): string {
    return p.split('/').pop() || p;
  }
  private scalar(v: unknown): string {
    return v === null || v === undefined ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v);
  }
  private flat(v: Record<string, unknown>, fmt: string | null): [string, unknown][] {
    return fmt === 'keyvalue' || fmt === null ? Object.entries(v) : this.flatten(v);
  }
  private flatKeys(v: Record<string, unknown>, fmt: string | null): string[] {
    return this.flat(v, fmt).map(([k]) => k);
  }
  private policyKeys(path: string): string[] {
    const p = this.policyFor(path);
    return p ? this.flatKeys(p.values, p.format) : [];
  }
  private flatten(v: Record<string, unknown>, prefix = ''): [string, unknown][] {
    const out: [string, unknown][] = [];
    for (const [k, val] of Object.entries(v)) {
      const key = prefix ? `${prefix}.${k}` : k;
      if (val !== null && typeof val === 'object' && !Array.isArray(val)) out.push(...this.flatten(val as Record<string, unknown>, key));
      else out.push([key, val]);
    }
    return out;
  }
  private unflatten(key: string, value: unknown, deep: boolean): Record<string, unknown> {
    if (!deep || !key.includes('.')) return { [key]: value };
    const parts = key.split('.');
    const root: Record<string, unknown> = {};
    let node = root;
    for (const p of parts.slice(0, -1)) {
      const n: Record<string, unknown> = {};
      node[p] = n;
      node = n;
    }
    node[parts[parts.length - 1]] = value;
    return root;
  }
}
