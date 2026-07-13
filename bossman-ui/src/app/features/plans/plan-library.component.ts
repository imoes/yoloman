import { AfterViewInit, Component, ElementRef, OnDestroy, ViewChild, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonToggleModule } from '@angular/material/button-toggle';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import * as monaco from 'monaco-editor';
import { PlanDocument, PlanService, PlanVersion, StoredPlan } from '../../core/services/plan.service';
import { DialogService } from '../../shared/dialogs/dialog.service';

(self as unknown as { MonacoEnvironment: unknown }).MonacoEnvironment = {
  getWorker() {
    return new Worker(URL.createObjectURL(new Blob(['self.onmessage=function(){}'], { type: 'text/javascript' })));
  },
};

type Fmt = 'nt' | 'yaml' | 'json';
interface Row { kind: 'folder' | 'plan'; label: string; depth: number; path?: string; plan?: StoredPlan; expanded?: boolean; }

/** Plan library (block 2): plans/roles organized in an ltree folder tree on the
 * left; selecting one opens it in a Monaco editor on the right with an
 * NT / YAML / JSON toggle (all three derive from the one canonical JSON body).
 * Move places a plan into a folder; Save stores the edited text as a new
 * version in the chosen format. */
@Component({
  selector: 'app-plan-library',
  standalone: true,
  imports: [FormsModule, MatButtonModule, MatIconModule, MatButtonToggleModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-pl">
      <aside class="bm-pl-tree">
        <div class="bm-pl-head">
          <strong>Plan library</strong>
          <span class="bm-spacer"></span>
          <button mat-icon-button (click)="openImport()" title="Import a plan (Ansible / Salt / Puppet / Chef)"><mat-icon>upload_file</mat-icon></button>
          <button mat-icon-button (click)="reload()" [disabled]="loading()" title="Reload"><mat-icon>refresh</mat-icon></button>
        </div>
        @if (loadErr()) { <p class="bm-err">{{ loadErr() }}</p> }
        <ul>
          @for (r of rows(); track r.kind + (r.path || '') + (r.plan?.prefix + '/' + r.plan?.name)) {
            @if (r.kind === 'folder') {
              <li class="bm-fold" [style.padding-left.px]="8 + r.depth * 16" (click)="toggle(r.path!)">
                <mat-icon>{{ expanded().has(r.path!) ? 'folder_open' : 'folder' }}</mat-icon>{{ r.label }}
              </li>
            } @else {
              <li class="bm-plan" [class.bm-sel]="isSel(r.plan!)" [style.padding-left.px]="8 + r.depth * 16" (click)="open(r.plan!)">
                <mat-icon>description</mat-icon>{{ r.label }}
                <span class="bm-badge">{{ r.plan!.prefix }}</span>
              </li>
            }
          }
          @if (!rows().length && !loading()) { <li class="bm-empty">No stored plans.</li> }
        </ul>
      </aside>

      <section class="bm-pl-editor">
        @if (doc(); as d) {
          <div class="bm-pl-bar">
            <span class="bm-pl-name">{{ d.prefix }}/{{ d.name }} <span class="bm-dim">v{{ d.version }}</span></span>
            <mat-button-toggle-group [value]="fmt()" (change)="setFmt($event.value)" hideSingleSelectionIndicator [disabled]="diffMode()">
              <mat-button-toggle value="nt">NT</mat-button-toggle>
              <mat-button-toggle value="yaml">YAML</mat-button-toggle>
              <mat-button-toggle value="json">JSON</mat-button-toggle>
            </mat-button-toggle-group>
            @if (versions().length > 1) {
              <select class="bm-diff-sel" [ngModel]="diffVersion()" (ngModelChange)="onDiff($event)" title="Compare with an older version">
                <option [ngValue]="null">edit (v{{ d.version }})</option>
                @for (v of versions(); track v.version) {
                  @if (v.version !== d.version) { <option [ngValue]="v.version">diff ⟷ v{{ v.version }}</option> }
                }
              </select>
            }
            <span class="bm-spacer"></span>
            <input class="bm-move" type="text" placeholder="folder (linux/base)" [(ngModel)]="moveFolder" (keyup.enter)="doMove()" />
            <button mat-stroked-button (click)="doMove()" [disabled]="busy()"><mat-icon>drive_file_move</mat-icon> Move</button>
            <button mat-raised-button color="primary" (click)="doSave()" [disabled]="busy()"><mat-icon>save</mat-icon> Save</button>
            <button mat-stroked-button color="warn" (click)="doDelete()" [disabled]="busy()"><mat-icon>delete</mat-icon> Delete</button>
          </div>
          @if (msg()) { <p class="bm-ok">{{ msg() }}</p> }
          @if (saveErr()) { <p class="bm-err">{{ saveErr() }}</p> }
        } @else if (importOpen()) {
          <div class="bm-import">
            <h3>Import a plan</h3>
            <p class="bm-dim">Paste an Ansible / Salt / Puppet / Chef source; Bossman parses it into the canonical plan format.</p>
            <label>Source type
              <select [(ngModel)]="impKind">
                @for (k of importKinds; track k.label; let i = $index) { <option [ngValue]="i">{{ k.label }}</option> }
              </select>
            </label>
            <label>Plan name
              <input type="text" [(ngModel)]="impName" placeholder="e.g. install_nginx" />
            </label>
            <label>Source
              <textarea [(ngModel)]="impText" rows="12" placeholder="paste the {{ importKinds[impKind()].label }} source here"></textarea>
            </label>
            <div class="bm-import-actions">
              <button mat-raised-button color="primary" (click)="doImport()" [disabled]="impBusy() || !impName.trim() || !impText.trim()">
                <mat-icon>upload_file</mat-icon> Import
              </button>
              <button mat-stroked-button (click)="importOpen.set(false)" [disabled]="impBusy()">Cancel</button>
            </div>
            @if (impErr()) { <p class="bm-err">{{ impErr() }}</p> }
          </div>
        } @else {
          <p class="bm-empty bm-pad">Select a plan from the tree to view / edit it (NT · YAML · JSON), or import one.</p>
        }
        <!-- Single, stable editor element (Monaco lives here for the panel's
             lifetime); hidden until a plan is opened or when diffing. -->
        <div class="bm-pl-mon" #editor [style.display]="doc() && !diffMode() ? 'block' : 'none'"></div>
        <div class="bm-pl-mon" #diffEditor [style.display]="diffMode() ? 'block' : 'none'"></div>
      </section>
    </div>
  `,
  styles: [
    `
      .bm-pl { display: grid; grid-template-columns: 320px 1fr; gap: 12px; height: calc(100vh - 120px); padding: 12px; }
      @media (max-width: 900px) { .bm-pl { grid-template-columns: 1fr; height: auto; } }
      .bm-pl-tree { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: auto; display: flex; flex-direction: column; }
      .bm-pl-head { display: flex; align-items: center; justify-content: space-between; padding: 8px 12px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
      .bm-pl-tree ul { list-style: none; margin: 0; padding: 0; overflow: auto; }
      .bm-pl-tree li { display: flex; align-items: center; gap: 6px; padding: 5px 8px; cursor: pointer; font-size: 13px; }
      .bm-pl-tree li mat-icon { font-size: 17px; width: 17px; height: 17px; opacity: 0.7; }
      .bm-fold { font-weight: 600; }
      .bm-plan:hover { background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent); }
      .bm-plan.bm-sel { background: color-mix(in srgb, var(--mat-sys-primary) 14%, transparent); }
      .bm-badge { margin-left: auto; font-size: 10.5px; padding: 0 6px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); opacity: 0.7; }
      .bm-empty { opacity: 0.6; cursor: default; }
      .bm-pad { padding: 16px; }
      .bm-pl-editor { display: flex; flex-direction: column; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: hidden; min-height: 400px; }
      .bm-pl-bar { display: flex; align-items: center; gap: 10px; padding: 6px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); flex-wrap: wrap; }
      .bm-pl-name { font-family: monospace; font-weight: 600; }
      .bm-dim { opacity: 0.5; font-weight: 400; }
      .bm-spacer { flex: 1; }
      .bm-move { padding: 5px 8px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 5px; background: var(--mat-sys-surface); color: inherit; font-size: 12px; width: 150px; }
      .bm-diff-sel { padding: 5px 7px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 5px; background: var(--mat-sys-surface); color: inherit; font-size: 12px; }
      .bm-pl-mon { flex: 1; min-height: 340px; }
      .bm-ok { color: #2e7d32; font-size: 12px; margin: 4px 10px; }
      .bm-err { color: #c62828; font-size: 12px; margin: 4px 10px; }
      .bm-import { padding: 16px 18px; display: flex; flex-direction: column; gap: 12px; overflow: auto; }
      .bm-import h3 { margin: 0; }
      .bm-import label { display: flex; flex-direction: column; gap: 4px; font-size: 12px; font-weight: 600; }
      .bm-import select, .bm-import input, .bm-import textarea {
        padding: 7px 9px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px;
        background: var(--mat-sys-surface); color: inherit; font-size: 13px; font-weight: 400;
      }
      .bm-import textarea { font-family: monospace; font-size: 12.5px; resize: vertical; }
      .bm-import-actions { display: flex; gap: 10px; }
    `,
  ],
})
export class PlanLibraryComponent implements AfterViewInit, OnDestroy {
  private planService = inject(PlanService);
  private dialog = inject(DialogService);
  @ViewChild('editor') editorEl!: ElementRef<HTMLDivElement>;
  @ViewChild('diffEditor') diffEditorEl!: ElementRef<HTMLDivElement>;

  plans = signal<StoredPlan[]>([]);
  versions = signal<PlanVersion[]>([]);
  diffVersion = signal<number | null>(null);
  diffMode = computed(() => this.diffVersion() !== null);
  private diffEd?: monaco.editor.IStandaloneDiffEditor;
  loading = signal(false);
  loadErr = signal<string | null>(null);
  expanded = signal<Set<string>>(new Set(['']));
  doc = signal<PlanDocument | null>(null);
  fmt = signal<Fmt>('nt');
  busy = signal(false);
  msg = signal<string | null>(null);
  saveErr = signal<string | null>(null);
  moveFolder = '';
  private ed?: monaco.editor.IStandaloneCodeEditor;

  // Import a foreign-DSL source as a stored plan.
  readonly importKinds = [
    { label: 'Ansible (YAML)', prefix: 'ansible', format: 'yaml' },
    { label: 'Ansible (JSON)', prefix: 'ansible', format: 'json' },
    { label: 'Ansible (NestedText)', prefix: 'ansible', format: 'nestedtext' },
    { label: 'Salt (SLS)', prefix: 'salt', format: 'salt' },
    { label: 'Puppet (manifest)', prefix: 'puppet', format: 'puppet' },
    { label: 'Chef (recipe)', prefix: 'chef', format: 'chef' },
  ];
  importOpen = signal(false);
  impKind = signal(0);
  impName = '';
  impText = '';
  impBusy = signal(false);
  impErr = signal<string | null>(null);

  /** Flatten plans into an indented folder tree honoring the expanded set. */
  rows = computed<Row[]>(() => {
    const byFolder = new Map<string, StoredPlan[]>();
    for (const p of this.plans()) {
      const f = p.folder || '';
      (byFolder.get(f) ?? byFolder.set(f, []).get(f)!).push(p);
    }
    // collect all folder paths (incl. ancestors)
    const folders = new Set<string>(['']);
    for (const f of byFolder.keys()) {
      const segs = f ? f.split('/') : [];
      for (let i = 0; i <= segs.length; i++) folders.add(segs.slice(0, i).join('/'));
    }
    const childFolders = (parent: string) =>
      [...folders].filter((f) => f && (parent ? f.startsWith(parent + '/') : true) &&
        f.split('/').length === (parent ? parent.split('/').length + 1 : 1)).sort();

    const out: Row[] = [];
    const walk = (folder: string, depth: number) => {
      for (const cf of childFolders(folder)) {
        out.push({ kind: 'folder', label: cf.split('/').pop()!, depth, path: cf });
        if (this.expanded().has(cf)) walk(cf, depth + 1);
      }
      for (const p of (byFolder.get(folder) ?? []).sort((a, b) => a.name.localeCompare(b.name))) {
        out.push({ kind: 'plan', label: p.name, depth, plan: p });
      }
    };
    walk('', 0);
    return out;
  });

  ngAfterViewInit(): void {
    // NOTE: do NOT create Monaco here — the editor panel is display:none until a
    // plan is selected, and Monaco created in a 0×0 container renders its lines
    // at the page's top-left. It's created lazily in applyFmt() once visible.
    this.reload();
  }

  ngOnDestroy(): void { this.ed?.dispose(); this.diffEd?.dispose(); }

  reload(): void {
    this.loading.set(true);
    this.loadErr.set(null);
    this.planService.library().subscribe({
      next: (r) => { this.plans.set(r.plans ?? []); this.loading.set(false); },
      error: (e) => { this.loading.set(false); this.loadErr.set(e?.error?.detail ?? 'failed to load library'); },
    });
  }

  toggle(path: string): void {
    const s = new Set(this.expanded());
    s.has(path) ? s.delete(path) : s.add(path);
    this.expanded.set(s);
  }

  isSel(p: StoredPlan): boolean { const d = this.doc(); return !!d && d.prefix === p.prefix && d.name === p.name; }

  open(p: { prefix: string; name: string }): void {
    this.msg.set(null); this.saveErr.set(null); this.diffVersion.set(null);
    this.planService.document(p.prefix, p.name).subscribe({
      next: (d) => {
        this.doc.set(d);
        this.moveFolder = d.folder;
        this.fmt.set(d.source_format === 'yaml' ? 'yaml' : d.source_format === 'json' ? 'json' : 'nt');
        this.applyFmt();
      },
      error: (e) => this.saveErr.set(e?.error?.detail ?? 'failed to load document'),
    });
    this.planService.versions(p.prefix, p.name).subscribe({ next: (r) => this.versions.set(r.versions ?? []), error: () => this.versions.set([]) });
  }

  /** Compare the current version with an older one in a Monaco diff editor
   * (JSON both sides). null → back to the normal edit view. */
  onDiff(version: number | null): void {
    this.diffVersion.set(version);
    const d = this.doc();
    if (version === null) { setTimeout(() => this.ed?.layout(), 0); return; } // back to edit → re-fit
    if (!d) return;
    this.planService.document(d.prefix, d.name, version).subscribe({
      next: (old) => {
        if (!this.diffEd) {
          this.diffEd = monaco.editor.createDiffEditor(this.diffEditorEl.nativeElement, {
            readOnly: true, automaticLayout: true, fontSize: 12, renderSideBySide: true,
            theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'vs-dark' : 'vs',
          });
        }
        this.diffEd.setModel({
          original: monaco.editor.createModel(old.formats.json, 'json'),
          modified: monaco.editor.createModel(d.formats.json, 'json'),
        });
        setTimeout(() => this.diffEd?.layout(), 0);
      },
      error: (e) => this.saveErr.set(e?.error?.detail ?? 'failed to load version'),
    });
  }

  setFmt(f: Fmt): void { this.fmt.set(f); this.applyFmt(); }

  private applyFmt(): void {
    const d = this.doc();
    if (!d) return;
    const f = this.fmt();
    // Deferred so the panel's display:block binding (set when doc() changed) has
    // applied — Monaco must be created/laid out in a visible, sized container.
    setTimeout(() => {
      if (!this.ed) {
        this.ed = monaco.editor.create(this.editorEl.nativeElement, {
          value: '', language: 'yaml', automaticLayout: true, minimap: { enabled: false },
          fontSize: 12, scrollBeyondLastLine: false,
          theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'vs-dark' : 'vs',
        });
      }
      this.ed.setValue(d.formats[f] ?? '');
      const model = this.ed.getModel();
      if (model) monaco.editor.setModelLanguage(model, f === 'json' ? 'json' : 'yaml');
      this.ed.layout();
    }, 0);
  }

  doMove(): void {
    const d = this.doc();
    if (!d) return;
    this.busy.set(true); this.msg.set(null); this.saveErr.set(null);
    this.planService.move(d.prefix, d.name, this.moveFolder.trim()).subscribe({
      next: (r) => { this.busy.set(false); this.msg.set(`moved to ${r.folder || 'root'}`); this.doc.set({ ...d, folder: r.folder }); this.reload(); },
      error: (e) => { this.busy.set(false); this.saveErr.set(e?.error?.detail ?? 'move failed'); },
    });
  }

  openImport(): void {
    this.doc.set(null);
    this.impErr.set(null);
    this.importOpen.set(true);
  }

  doImport(): void {
    const kind = this.importKinds[this.impKind()];
    const name = this.impName.trim();
    const text = this.impText.trim();
    if (!name || !text) return;
    this.impBusy.set(true); this.impErr.set(null);
    this.planService.import(kind.prefix, name, kind.format, text).subscribe({
      next: (r) => {
        this.impBusy.set(false);
        this.importOpen.set(false);
        this.impName = ''; this.impText = '';
        this.reload();
        this.open({ prefix: r.prefix, name: r.name });
      },
      error: (e) => { this.impBusy.set(false); this.impErr.set(e?.error?.detail ?? 'import failed'); },
    });
  }

  async doDelete(): Promise<void> {
    const d = this.doc();
    if (!d) return;
    if (!(await this.dialog.confirm({ title: 'Delete plan', message: `Delete plan "${d.prefix}/${d.name}" and all its versions? This cannot be undone.`, confirmText: 'Delete', danger: true }))) return;
    this.busy.set(true); this.msg.set(null); this.saveErr.set(null);
    this.planService.delete(d.prefix, d.name).subscribe({
      next: (r) => {
        this.busy.set(false);
        this.doc.set(null);
        this.versions.set([]);
        this.msg.set(`deleted ${r.deleted_versions} version(s)`);
        this.reload();
      },
      error: (e) => { this.busy.set(false); this.saveErr.set(e?.error?.detail ?? 'delete failed'); },
    });
  }

  doSave(): void {
    const d = this.doc();
    if (!d || !this.ed) return;
    const f = this.fmt();
    const sourceFormat = f === 'nt' ? 'nestedtext' : f;
    this.busy.set(true); this.msg.set(null); this.saveErr.set(null);
    this.planService.save(d.prefix, d.name, sourceFormat, this.ed.getValue()).subscribe({
      next: (r) => { this.busy.set(false); this.msg.set(`saved as v${r.version}`); this.open({ prefix: d.prefix, name: d.name }); this.reload(); },
      error: (e) => { this.busy.set(false); this.saveErr.set(e?.error?.detail ?? 'save failed'); },
    });
  }
}
