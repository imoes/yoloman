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
import { ConditionsEditorComponent } from '../../shared/components/conditions-editor/conditions-editor.component';

interface ScopePolicy {
  id: string;
  path: string;
  type: string;
  format: string | null;
  separator: string | null;
  values: Record<string, unknown>;
  template: string | null;
  conditions?: Record<string, unknown>;
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
  value: unknown;
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
  imports: [FormsModule, MatIconModule, MatButtonModule, ConditionsEditorComponent],
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
            @if (!writesPerKey(sel)) {
              <p class="bm-dim">{{ noPerKeyReason(sel) }}</p>
            }
            @if (machineWritten(sel); as mw) {
              <p class="bm-dim">This file says it is machine-written (line {{ mw.line }}):
                <em>{{ mw.quote }}</em> — a policy on it may be discarded the next time it is generated.</p>
            }
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
                  @if (dsIsJson()) {
                    <textarea class="bm-oce-val bm-oce-json" rows="4" [ngModel]="value()" (ngModelChange)="value.set($event)"
                              placeholder='["a", "b"] or a JSON object'></textarea>
                    <p class="bm-oce-src">This setting is a {{ directiveSpec()?.type === 'list' ? 'list' : 'structure' }} — enter it as JSON; it is stored and applied as a real structure.</p>
                  } @else if (valueOptions(); as opts) {
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
            @if (deferApply) {
              <!-- Checkmk match conditions for THIS file (staged with the values;
                   Save commits, Cancel discards). Empty = applies wherever the
                   scope reaches. -->
              <div class="bm-oce-cond">
                <app-conditions-editor [conditions]="condFor(sel)" (conditionsChange)="setCond(sel, $event)" [previewScope]="previewScope()" />
              </div>
            }
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
      .bm-oce-cond { margin-top: 14px; padding-top: 12px; border-top: 1px solid var(--mat-sys-outline-variant); }
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

  /** Scope for the conditions editor's blast-radius preview — only concrete
   * scopes (ou/group/site); unlinked/set policies have no host set to preview. */
  previewScope(): { scope_type: string; ou_id?: string; host_group_id?: string; site_id?: string } | undefined {
    const s = this.scope;
    if (s.kind === 'ou' && s.id) return { scope_type: 'ou', ou_id: s.id };
    if (s.kind === 'group' && s.id) return { scope_type: 'group', host_group_id: s.id };
    if (s.kind === 'site' && s.id) return { scope_type: 'site', site_id: s.id };
    return undefined;
  }

  loaded = signal(false);
  // ADMX per-directive value catalog (parity with the host gpedit) — loaded once.
  // Kept ONLY as the cross-file search index (which keys exist in each file); the
  // SELECTED file's editing specs come from describe() (config-fields) instead —
  // see fieldsForSelected + specsForFile (config-model consolidation).
  directiveCatalog = signal<Record<string, Record<string, DirectiveSpec>>>({});
  // The unified field specs for the SELECTED file, from GET /config-fields
  // (derive_schema: codec ⊕ directive, or the template's schema.json) — the ONE
  // describe() source the host gpedit + ParamForm also use.
  private fieldsForSelected = signal<{ path: string; specs: Record<string, DirectiveSpec> }>({ path: '', specs: {} });
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
  // Staged edits in deferred mode, keyed by `${path}\u0000${key}` so a key can be
  // re-edited before Save. Empty in immediate mode.
  pending = signal<Map<string, PendingEdit>>(new Map());
  private pk(path: string, key: string): string { return `${path}\u0000${key}`; }
  pendingCount(): number { return this.pending().size + this.condDirty.size; }
  // Per-file (path) Checkmk match conditions, editable below the settings (dialog
  // only). Seeded from the policy at this scope; condDirty remembers files whose
  // conditions changed so saveAll writes them even without a value edit.
  condByPath = signal<Map<string, Record<string, unknown>>>(new Map());
  private condDirty = new Set<string>();
  condFor(path: string): Record<string, unknown> {
    return this.condByPath().get(path) ?? this.policyFor(path)?.conditions ?? {};
  }
  setCond(path: string, c: Record<string, unknown>): void {
    const next = new Map(this.condByPath());
    next.set(path, c);
    this.condByPath.set(next);
    this.condDirty.add(path);
  }

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
    this.condByPath.set(new Map());
    this.condDirty.clear();
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
    this.agentService.configGenerated().subscribe({
      next: (r) => this.generatedFiles.set(r.files || {}),
      error: () => {},
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
          // KEEP THE MEASURED CODEC — `none` means the round-trip probe applied every codec to the bytes the
          // package ships and none reproduced the file, so there is no per-key write for it. Coercing it to
          // `keyvalue` (as this did) made a per-key POLICY offerable for 40 such paths; the policy would be
          // stored, win at its scope, and then have no writer on the host. Same fix as the host editor.
          files.push({ path, format: e.codec ?? '' });
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
    // The selected file's specs come from describe() (config-fields); other files
    // fall back to the bulk directive catalog (the cross-file search index).
    const sel = this.fieldsForSelected();
    if (sel.path === path && Object.keys(sel.specs).length) return sel.specs;
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
    if (path) {
      this.selectedCat.set(categorizeConfigPath(path).key);
      this.loadFields(path);
    }
  }

  /** Fetch the SELECTED file's unified field specs from describe() and map the
   * FieldDef shape ({type:'enum', enum:[…]}) onto the DirectiveSpec the controls
   * read ({type, values:[…]}). This is what makes the OU editor's controls typed
   * from the same source as the host gpedit (and picks up codec⊕directive merges
   * + template-schema fields the raw directive catalog alone doesn't carry). */
  private loadFields(path: string): void {
    this.agentService.configFields(path).subscribe({
      next: (r) => {
        const specs: Record<string, DirectiveSpec> = {};
        for (const [k, fd] of Object.entries(r.fields || {})) {
          const t = fd.type === 'number' ? 'int' : fd.type;
          specs[k] = {
            type: (fd.enum?.length ? 'enum' : t) as DirectiveSpec['type'],
            values: fd.enum,
            default: fd.default != null ? String(fd.default) : undefined,
            description: fd.description,
            min: fd.min, max: fd.max,
          };
        }
        this.fieldsForSelected.set({ path, specs });
      },
      error: () => this.fieldsForSelected.set({ path, specs: {} }),
    });
  }

  policyFor(path: string): ScopePolicy | undefined {
    return this.policies().find((p) => p.path === path);
  }

  /** path -> the file's own sentence about being machine-written (GET /config-generated). A policy is
   * worse than a host edit here: it is stored, wins at its scope, and gets overwritten on every generator
   * run, so the console would keep reporting drift it cannot fix. Quoted, not blocked. */
  generatedFiles = signal<Record<string, { line: number; quote: string; marker: string }>>({});

  machineWritten(path: string): { line: number; quote: string; marker: string } | null {
    return this.generatedFiles()[path] ?? null;
  }

  /** Can this file be written ONE KEY AT A TIME? The measured codec decides — `none` means no codec
   * reproduced the shipped bytes, so there is no per-key writer and a per-key policy could never be
   * applied. Empty means the file was never measured. Neither is a per-key target. */
  writesPerKey(path: string): boolean {
    const fmt = (this.catalog().find((r) => r.path === path)?.format
                 ?? this.policyFor(path)?.format ?? '').toLowerCase();
    return !!fmt && fmt !== 'none';
  }

  /** The reason the settings list is empty, in the operator's words — a refusal has to name its ground. */
  noPerKeyReason(path: string): string {
    const fmt = (this.catalog().find((r) => r.path === path)?.format ?? '').toLowerCase();
    return fmt === 'none'
      ? 'No codec reproduces this file, so it cannot be policed setting by setting — it is written as a whole by its template.'
      : 'This file has never been measured, so no per-key policy is offered for it yet.';
  }

  rows(): SettingRow[] {
    const path = this.selected();
    if (!path) return [];
    // A file with no per-key writer gets no rows: offering a policy that cannot be applied is the defect
    // this replaced (the picker used to relabel a measured `none` as `keyvalue`).
    if (!this.writesPerKey(path)) return [];
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
        base.policy = p.mode === 'configured' ? this.scalar(p.value) : '';
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
    const byPath = new Map<string, { fmt: string; values: Record<string, unknown>; unset: string[] }>();
    for (const e of map.values()) {
      const g = byPath.get(e.path) ?? { fmt: e.fmt || 'keyvalue', values: {}, unset: [] };
      if (e.mode === 'notconf') g.unset.push(e.key);
      else Object.assign(g.values, this.unflatten(e.key, e.mode === 'removed' ? null : e.value, e.fmt !== 'keyvalue'));
      byPath.set(e.path, g);
    }
    // A file whose ONLY change is its conditions still needs a write — ensure it
    // has an entry so its createConfigPolicy runs (empty values = conditions-only).
    for (const path of this.condDirty) {
      if (!byPath.has(path)) {
        const fmt = this.catalog().find((r) => r.path === path)?.format ?? this.policyFor(path)?.format ?? 'keyvalue';
        byPath.set(path, { fmt, values: {}, unset: [] });
      }
    }
    if (!byPath.size) return of(null);
    const ops: Observable<unknown>[] = [];
    for (const [path, g] of byPath) {
      const cond = this.condFor(path);
      // Write the policy when it has values OR carries conditions (so a
      // conditions-only edit persists); the backend replaces conditions wholesale.
      if (Object.keys(g.values).length || Object.keys(cond).length || this.condDirty.has(path)) {
        ops.push(this.ouService.createConfigPolicy({ ...this.scopeArg(), path, format: g.fmt, values: g.values, conditions: cond }));
      }
      for (const key of g.unset) if (this.policyFor(path)) ops.push(this.ouService.unsetConfigPolicyKey({ ...this.scopeArg(), path, key }));
    }
    if (!ops.length) { this.clearStaged(); return of(null); }
    return forkJoin(ops).pipe(tap(() => this.clearStaged()));
  }

  private clearStaged(): void {
    this.pending.set(new Map());
    this.condByPath.set(new Map());
    this.condDirty.clear();
  }

  /** Drop all staged edits (deferred/dialog Cancel) — nothing was persisted. */
  discardAll(): void {
    this.clearStaged();
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

  /** A playbook/config value is not only a scalar — LISTS and DICTS are common
   * (`packages: [nginx, git]`, `nginx: {worker_processes: 4}`). Edit those as
   * JSON: true for a `list` directive, or — when the catalog has no scalar type
   * for the key — when the current value already looks like JSON. Scalar-typed
   * directives (enum/bool/int/string) never switch to JSON. Mirrors the scope
   * ScopeVarsDialog so policy values match host_vars. */
  dsIsJson(): boolean {
    const t = this.directiveSpec()?.type;
    if (t === 'list') return true;
    if (t === 'enum' || t === 'bool' || t === 'int' || t === 'string') return false;
    const v = this.value().trim();
    return v.startsWith('[') || v.startsWith('{');
  }

  /** The value to store for this edit — a real structure for JSON kinds (policy
   * `values` is JSONB), a plain string otherwise, null when Removed. Sets
   * `error` and returns ok:false on invalid JSON so apply() can bail. */
  private storeValue(): { ok: boolean; value: unknown } {
    if (this.mode() === 'removed') return { ok: true, value: null };
    const raw = this.value();
    if (!this.dsIsJson()) return { ok: true, value: raw };
    let parsed: unknown;
    try { parsed = JSON.parse(raw); } catch { this.error.set('Invalid JSON.'); return { ok: false, value: null }; }
    if (parsed === null || typeof parsed !== 'object') {
      this.error.set('Enter a JSON array or object.');
      return { ok: false, value: null };
    }
    return { ok: true, value: parsed };
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
    this.error.set(null);
    // Parse list/dict values to real structures up front (so both the staged and
    // the immediate path store the structure, not its JSON text); bail on bad JSON.
    const sv = this.storeValue();
    if (!sv.ok) return;
    // Deferred mode: stage the edit and update the row overlay; nothing hits the
    // API until the dialog's Save (saveAll). Re-editing a key replaces its entry.
    if (this.deferApply) {
      const next = new Map(this.pending());
      next.set(this.pk(path, key), { path, key, mode: this.mode(), value: sv.value, fmt });
      this.pending.set(next);
      this.editKey.set(null);
      return;
    }
    this.busy.set(true);
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
    const values = this.unflatten(key, sv.value, fmt !== 'keyvalue');
    this.ouService.createConfigPolicy({ ...this.scopeArg(), path, format: fmt ?? 'keyvalue', values, conditions: this.condFor(path) }).subscribe({
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
