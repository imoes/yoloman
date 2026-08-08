import { Component, OnChanges, SimpleChanges, Input, inject, signal } from '@angular/core';
import { Observable, forkJoin, of } from 'rxjs';
import { tap } from 'rxjs/operators';
import { FormsModule } from '@angular/forms';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AgentService } from '../../core/services/agent.service';
import { OuService } from '../../core/services/ou.service';
import { HostGroupService } from '../../core/services/host-group.service';
import { DialogService } from '../../shared/dialogs/dialog.service';
import { DirectiveSpec } from '../../core/models/agent.model';
import { ConfigCategory, categorizeConfigPath, groupByCategory } from '../../shared/config-categories';

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
  state: 'Configured' | 'Removed' | 'Host based';
  policy: string;
  live: string;
  /** True when this row's state comes from an unsaved (staged) edit — shown with
   * a • marker in the deferred (dialog) mode where Save commits, Cancel discards. */
  pending?: boolean;
}

/** One staged edit in the deferred (dialog Save/Cancel) mode. */
interface PendingEdit {
  path: string;
  key: string;
  mode: 'configured' | 'removed' | 'notconf';
  value: string;
  fmt: string;
}

/** What the gpedit editor is scoped to — an OU or a host group. For a group
 * the catalog host is resolved from its member agent ids (an OU resolves it
 * from its subtree members endpoint). */
export interface EditorScope {
  // 'unlinked' authors a scope-less policy (GPMC "create a GPO, link it later").
  // 'set' authors ENTRIES of a named policy (ConfigPolicySet) — id is the set id;
  // entries inherit the set's scope on save.
  kind: 'ou' | 'group' | 'site' | 'unlinked' | 'set';
  id?: string;
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
      <p class="bm-oce-src">Policies set here apply down to every host under this {{ scopeWord }}; a host's own config overrides them. Pick from every known config file (the codec registry) — the host doesn't need the file yet.</p>
      <input class="bm-oce-search" type="search" placeholder="Search settings…" [ngModel]="search()" (ngModelChange)="search.set($event)" />
      <!-- Three Miller columns: Category → File → Settings. The settings column is
           always visible, so which values are Configured/Removed is never hidden
           behind a collapsed tree node. -->
      <div class="bm-oce-miller">
        <!-- Column 1: semantic categories. -->
        <div class="bm-oce-col bm-oce-col-cat">
          @for (grp of groups(); track grp.cat.key) {
            <div class="bm-oce-item" [class.bm-oce-sel]="activeCat() === grp.cat.key" (click)="selectCat(grp.cat.key)">
              <mat-icon class="bm-oce-cat-ic">{{ grp.cat.icon }}</mat-icon>
              <span class="bm-oce-tlabel">{{ grp.cat.label }}</span>
              <span class="bm-oce-count">{{ grp.files.length }}</span>
            </div>
          } @empty {
            <p class="bm-oce-empty">{{ loaded() ? 'Nothing matches.' : 'Loading…' }}</p>
          }
        </div>
        <!-- Column 2: the files in the active category; ● marks a file that has a
             policy at this scope. -->
        <div class="bm-oce-col bm-oce-col-file">
          @for (f of filesInCat(); track f.path) {
            <div class="bm-oce-item" [class.bm-oce-sel]="selected() === f.path" (click)="select(f.path)" [title]="f.path">
              <span class="bm-oce-tlabel">{{ baseName(f.path) }}</span>
              @if (policyFor(f.path)) { <span class="bm-oce-dot" title="policy at this scope">●</span> }
            </div>
          } @empty {
            <p class="bm-oce-empty">Pick a category.</p>
          }
        </div>
        <!-- Column 3: the selected file's settings — Setting / State / value / default. -->
        <div class="bm-oce-col bm-oce-col-set">
          @if (selected(); as sel) {
            <div class="bm-oce-file-hd">
              <h4 class="bm-oce-file-h">{{ sel }}</h4>
              @if (policyFor(sel)) {
                <button mat-stroked-button class="bm-oce-del" (click)="deletePolicy(sel)" [disabled]="busy()"
                        title="Delete the whole policy for this file at this scope">
                  <mat-icon>delete_outline</mat-icon> Remove policy
                </button>
              }
            </div>
            <table class="bm-oce-settings">
              <thead><tr><th>Setting</th><th>State</th><th>Policy value</th><th>Default</th></tr></thead>
              <tbody>
                @for (row of rows(); track row.key) {
                  <tr (click)="openRow(row)" [class.bm-oce-row-sel]="editKey() === row.key" [class.bm-oce-managed]="row.state !== 'Host based'" [class.bm-oce-pending]="row.pending">
                    <td class="bm-oce-key">@if (row.pending) { <span class="bm-oce-pdot" title="staged — not saved yet">•</span> }{{ row.key }}</td>
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
                <label class="bm-oce-radio"><input type="radio" name="ocemode" [checked]="mode() === 'notconf'" (change)="mode.set('notconf')" /> Host based — no policy at this {{ scopeWord }} (the host's own value applies)</label>
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
                  <button mat-flat-button color="primary" (click)="apply()" [disabled]="busy()">{{ deferApply ? 'Stage change' : 'Apply to ' + scopeWord }}</button>
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
      .bm-oce-search { display: block; width: 100%; max-width: 420px; margin: 2px 0 10px; padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font-size: 13px; box-sizing: border-box; }
      /* Three Miller columns (Category → File → Settings). Wraps on a narrow panel;
         each column scrolls on its own so a long list never pushes the page sideways. */
      .bm-oce-miller { display: flex; flex-wrap: wrap; gap: 10px; align-items: stretch; }
      .bm-oce-col { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 4px; font-size: 13px; max-height: 480px; overflow-y: auto; box-sizing: border-box; }
      .bm-oce-col-cat { flex: 0 0 210px; }
      .bm-oce-col-file { flex: 0 0 210px; }
      .bm-oce-col-set { flex: 1 1 340px; min-width: 0; padding: 10px; overflow-x: auto; }
      .bm-oce-item { padding: 6px 8px; cursor: pointer; display: flex; align-items: center; gap: 6px; border-left: 3px solid transparent; border-radius: 4px; user-select: none; }
      .bm-oce-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
      .bm-oce-item .bm-oce-count { margin-left: auto; font-size: 11px; opacity: 0.5; }
      .bm-oce-cat-ic { font-size: 16px; width: 16px; height: 16px; opacity: 0.8; flex: 0 0 16px; }
      .bm-oce-tlabel { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .bm-oce-sel { border-left-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); }
      .bm-oce-dot { color: var(--mat-sys-primary); font-size: 10px; margin-left: auto; }
      .bm-oce-live { max-width: 220px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .bm-oce-file-h { margin: 0 0 8px; font-family: ui-monospace, monospace; font-size: 14px; }
      .bm-oce-settings { width: 100%; border-collapse: collapse; font-size: 13px; }
      .bm-oce-settings th { text-align: left; font-size: 11px; opacity: 0.65; padding: 6px 10px; }
      .bm-oce-settings td { padding: 6px 10px; border-top: 1px solid var(--mat-sys-outline-variant); cursor: pointer; }
      .bm-oce-managed td { font-weight: 600; }
      .bm-oce-pending td { background: color-mix(in srgb, var(--mat-sys-tertiary) 12%, transparent); }
      .bm-oce-pdot { color: var(--mat-sys-tertiary); font-weight: 700; margin-right: 5px; }
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
  // Open directly ON this config file (a specific policy the user clicked to
  // edit), so its set values are visible immediately instead of an empty tree.
  @Input() initialPath?: string;
  // Deferred mode (the dialog): settings are STAGED, not applied on each Apply.
  // The dialog commits them all via saveAll() on Save, or drops them on Cancel.
  // Left false for the inline (host-group) editor, which applies immediately.
  @Input() deferApply = false;

  private agentService = inject(AgentService);
  private ouService = inject(OuService);
  private hostGroupService = inject(HostGroupService);
  private appDialog = inject(DialogService);

  get scopeWord(): string {
    return this.scope.kind === 'group' ? 'group' : this.scope.kind === 'site' ? 'site'
      : this.scope.kind === 'unlinked' ? 'unlinked policy' : this.scope.kind === 'set' ? 'policy' : 'OU';
  }
  private listArg() {
    return this.scope.kind === 'ou' ? { ouId: this.scope.id }
      : this.scope.kind === 'site' ? { siteId: this.scope.id }
      : this.scope.kind === 'set' ? { setId: this.scope.id }
      : this.scope.kind === 'unlinked' ? { unlinked: true }
      : { groupId: this.scope.id };
  }
  private scopeArg() {
    return this.scope.kind === 'ou' ? { scope_ou_id: this.scope.id }
      : this.scope.kind === 'site' ? { site_id: this.scope.id }
      : this.scope.kind === 'set' ? { set_id: this.scope.id }
      : this.scope.kind === 'unlinked' ? {}
      : { host_group_id: this.scope.id };
  }

  loaded = signal(false);
  // ADMX per-directive value catalog (parity with the host gpedit) — loaded once.
  directiveCatalog = signal<Record<string, Record<string, DirectiveSpec>>>({});
  // Host-independent file catalog: every known config file from the codec
  // registry ({path, format}). A policy can target any of them.
  private catalog = signal<{ path: string; format: string }[]>([]);
  private policies = signal<ScopePolicy[]>([]);
  search = signal('');
  // Miller column state: the selected category (col 1) and file (col 2); col 3
  // is the selected file's settings — so what's Configured is always on screen.
  selectedCat = signal<string | null>(null);
  selected = signal<string | null>(null);
  editKey = signal<string | null>(null);
  mode = signal<'notconf' | 'configured' | 'removed'>('configured');
  value = signal('');
  newKey = signal('');
  busy = signal(false);
  error = signal<string | null>(null);
  // Staged edits in deferred mode, keyed by `${path} ${key}` so a key can be
  // re-edited before Save. Empty in immediate mode.
  pending = signal<Map<string, PendingEdit>>(new Map());
  private pk(path: string, key: string): string { return `${path} ${key}`; }
  pendingCount(): number { return this.pending().size; }

  ngOnChanges(changes: SimpleChanges): void {
    if (changes['scope']) this.reload();
  }

  private reload(): void {
    this.loaded.set(false);
    this.catalog.set([]);
    this.policies.set([]);
    this.selected.set(null);
    this.editKey.set(null);
    this.pending.set(new Map());
    this.ouService.listConfigPolicies(this.listArg()).subscribe((ps) => {
      this.policies.set(ps);
      // Show set values right away: select the file the user came to edit, else
      // the first file that HAS a policy at this scope — so the configured values
      // are on screen immediately instead of an empty tree.
      if (!this.selected()) {
        const target = (this.initialPath && ps.some((p) => p.path === this.initialPath))
          ? this.initialPath
          : (ps[0]?.path ?? null);
        if (target) this.select(target);
      }
    });
    if (!Object.keys(this.directiveCatalog()).length) {
      this.agentService.configDirectives().subscribe({ next: (r) => this.directiveCatalog.set(r.directives || {}), error: () => {} });
    }
    // Host-independent file catalog: the codec registry lists every config file
    // we know how to parse — a policy can target any of them, whether or not a
    // member host currently has the file. Use the first concrete path per entry.
    this.agentService.configCodecs().subscribe({
      next: (r) => {
        const seen = new Set<string>();
        const files: { path: string; format: string }[] = [];
        for (const e of r.entries ?? []) {
          const path = (e.paths ?? []).find((p) => p && !p.includes('*')) ?? e.pattern;
          if (!path || path.includes('*') || seen.has(path)) continue;
          seen.add(path);
          files.push({ path, format: e.codec === 'none' ? 'keyvalue' : e.codec });
        }
        this.catalog.set(files);
        this.loaded.set(true);
      },
      error: () => this.loaded.set(true),
    });
  }

  /** Catalog files ∪ policy-only paths, category-grouped, search-filtered by
   * path or any setting key inside (mirrors the host gpedit's live search). */
  groups(): { cat: ConfigCategory; files: { path: string }[] }[] {
    const paths = new Set<string>();
    for (const r of this.catalog()) paths.add(r.path);
    for (const p of this.policies()) paths.add(p.path);
    const q = this.search().trim().toLowerCase();
    const items = [...paths]
      .filter((path) => {
        if (!q) return true;
        if (path.toLowerCase().includes(q)) return true;
        const keys = [...this.directiveKeysFor(path), ...this.policyKeys(path)];
        return keys.some((k) => k.toLowerCase().includes(q));
      })
      .map((path) => ({ path }));
    return groupByCategory(items);
  }

  /** The ADMX directive specs for a file. config_directives.json is keyed by FULL path
   * (e.g. /etc/apt/apt.conf.d/…); the basename is a fallback for any legacy name-keyed entry. Keying by
   * basename alone (the old bug) matched nothing, so every setting fell back to a generic text input
   * instead of the enum/bool/int field the catalog defines. */
  private specsForFile(path: string): Record<string, DirectiveSpec> {
    const cat = this.directiveCatalog();
    return cat[path] ?? cat[this.baseName(path)] ?? {};
  }

  /** Known setting keys for a file, from the ADMX directive catalog. */
  private directiveKeysFor(path: string): string[] {
    return Object.keys(this.specsForFile(path));
  }

  /** The effective category key for column 1's highlight and column 2's list —
   * the explicitly selected one, or the first visible category as a fallback. */
  activeCat(): string | null {
    const sel = this.selectedCat();
    const gs = this.groups();
    if (sel && gs.some((g) => g.cat.key === sel)) return sel;
    return gs[0]?.cat.key ?? null;
  }

  /** Column 2: the files in the active category (search already applied in groups()). */
  filesInCat(): { path: string }[] {
    const key = this.activeCat();
    return this.groups().find((g) => g.cat.key === key)?.files ?? [];
  }

  /** Column 1 click: pick a category and drill straight into its first file so
   * column 3 (the settings, with their set values) is never empty. */
  selectCat(key: string): void {
    this.selectedCat.set(key);
    const files = this.filesInCat();
    this.select(files[0]?.path ?? null);
  }

  select(path: string | null): void {
    this.selected.set(path);
    this.editKey.set(null);
    if (path) this.selectedCat.set(categorizeConfigPath(path).key);
  }

  policyFor(path: string): ScopePolicy | undefined {
    return this.policies().find((p) => p.path === path);
  }

  rows(): SettingRow[] {
    const path = this.selected();
    if (!path) return [];
    const fmt = this.catalog().find((r) => r.path === path)?.format ?? this.policyFor(path)?.format ?? 'keyvalue';
    const specs = this.specsForFile(path);
    const des = new Map(this.flat(this.policyFor(path)?.values ?? {}, fmt));
    // Staged edits for THIS file overlay the persisted values, and staged-only
    // keys join the list — so the settings column always shows what will be set.
    const pend = new Map<string, PendingEdit>();
    for (const e of this.pending().values()) if (e.path === path) pend.set(e.key, e);
    const keys = [...new Set([...Object.keys(specs), ...des.keys(), ...pend.keys()])].sort();
    const q = this.search().trim().toLowerCase();
    const all = keys.map((key): SettingRow => {
      const managed = des.has(key);
      const dv = des.get(key);
      const base: SettingRow = {
        key,
        state: managed ? (dv === null ? 'Removed' : 'Configured') : 'Host based',
        policy: dv === null || dv === undefined ? '' : this.scalar(dv),
        // No live host value here — show the directive default as a reference.
        live: this.scalar(specs[key]?.default ?? ''),
      };
      const p = pend.get(key);
      if (p) {
        base.pending = true;
        base.state = p.mode === 'notconf' ? 'Host based' : p.mode === 'removed' ? 'Removed' : 'Configured';
        base.policy = p.mode === 'configured' ? p.value : '';
      }
      return base;
    });
    if (!q || path.toLowerCase().includes(q)) return all;
    const hit = all.filter((r) => r.key.toLowerCase().includes(q));
    return hit.length ? hit : all;
  }

  /** Commit every staged edit (deferred/dialog mode): one createConfigPolicy per
   * file carrying its set/removed keys, plus an unset per "Host based" key.
   * Completes before the dialog closes so the page's reload sees the result. */
  saveAll(): Observable<unknown> {
    const map = this.pending();
    if (!map.size) return of(null);
    const byPath = new Map<string, { fmt: string; values: Record<string, unknown>; unset: string[] }>();
    for (const e of map.values()) {
      const g = byPath.get(e.path) ?? { fmt: e.fmt || 'keyvalue', values: {}, unset: [] };
      if (e.mode === 'notconf') g.unset.push(e.key);
      else Object.assign(g.values, this.unflatten(e.key, e.mode === 'removed' ? null : e.value, e.fmt !== 'keyvalue'));
      byPath.set(e.path, g);
    }
    const ops: Observable<unknown>[] = [];
    for (const [path, g] of byPath) {
      if (Object.keys(g.values).length) ops.push(this.ouService.createConfigPolicy({ ...this.scopeArg(), path, format: g.fmt, values: g.values }));
      for (const key of g.unset) if (this.policyFor(path)) ops.push(this.ouService.unsetConfigPolicyKey({ ...this.scopeArg(), path, key }));
    }
    if (!ops.length) { this.pending.set(new Map()); return of(null); }
    return forkJoin(ops).pipe(tap(() => this.pending.set(new Map())));
  }

  /** Drop all staged edits (deferred/dialog Cancel) — nothing was persisted. */
  discardAll(): void {
    this.pending.set(new Map());
    this.editKey.set(null);
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
    this.openRow({ key: k, state: 'Host based', policy: '', live: '' });
  }

  /** ADMX spec for the setting being edited (by file basename + key). */
  directiveSpec(): DirectiveSpec | null {
    const path = this.selected(), key = this.editKey();
    if (!path || !key) return null;
    return this.specsForFile(path)[key] ?? null;
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
    // Deferred mode: stage the edit and update the row overlay; nothing hits the
    // API until the dialog's Save (saveAll). Re-editing a key replaces its entry.
    if (this.deferApply) {
      const next = new Map(this.pending());
      next.set(this.pk(path, key), { path, key, mode: this.mode(), value: this.value(), fmt });
      this.pending.set(next);
      this.editKey.set(null);
      return;
    }
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

  /** Delete the WHOLE policy for a file at this scope (not just one key). Confirmed, since it removes every
   * setting the policy carries; member hosts reconverge to their own values on the next pass. */
  async deletePolicy(path: string): Promise<void> {
    const policy = this.policyFor(path);
    if (!policy) return;
    const ok = await this.appDialog.confirm({
      title: 'Remove policy',
      message: `Remove the entire policy for ${path} at this ${this.scopeWord}? Every setting it defines is dropped and member hosts reconverge to their own values.`,
      confirmText: 'Remove',
      danger: true,
    });
    if (!ok) return;
    this.busy.set(true);
    this.error.set(null);
    this.ouService.deleteConfigPolicy(policy.id).subscribe({
      next: () => {
        this.busy.set(false);
        this.editKey.set(null);
        this.ouService.listConfigPolicies(this.listArg()).subscribe((ps) => this.policies.set(ps));
      },
      error: (e: { error?: { detail?: string } }) => { this.error.set(e?.error?.detail ?? 'delete failed'); this.busy.set(false); },
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
