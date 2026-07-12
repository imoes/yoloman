import { AfterViewInit, Component, ElementRef, OnDestroy, ViewChild, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonToggleModule } from '@angular/material/button-toggle';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import * as monaco from 'monaco-editor';
import { PlanDocument, PlanService, StoredPlan } from '../../core/services/plan.service';

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
            <mat-button-toggle-group [value]="fmt()" (change)="setFmt($event.value)" hideSingleSelectionIndicator>
              <mat-button-toggle value="nt">NT</mat-button-toggle>
              <mat-button-toggle value="yaml">YAML</mat-button-toggle>
              <mat-button-toggle value="json">JSON</mat-button-toggle>
            </mat-button-toggle-group>
            <span class="bm-spacer"></span>
            <input class="bm-move" type="text" placeholder="folder (linux/base)" [(ngModel)]="moveFolder" (keyup.enter)="doMove()" />
            <button mat-stroked-button (click)="doMove()" [disabled]="busy()"><mat-icon>drive_file_move</mat-icon> Move</button>
            <button mat-raised-button color="primary" (click)="doSave()" [disabled]="busy()"><mat-icon>save</mat-icon> Save</button>
          </div>
          @if (msg()) { <p class="bm-ok">{{ msg() }}</p> }
          @if (saveErr()) { <p class="bm-err">{{ saveErr() }}</p> }
        } @else {
          <p class="bm-empty bm-pad">Select a plan from the tree to view / edit it (NT · YAML · JSON).</p>
        }
        <!-- Single, stable editor element (Monaco lives here for the panel's
             lifetime); hidden until a plan is opened. -->
        <div class="bm-pl-mon" #editor [style.display]="doc() ? 'block' : 'none'"></div>
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
      .bm-pl-mon { flex: 1; min-height: 340px; }
      .bm-ok { color: #2e7d32; font-size: 12px; margin: 4px 10px; }
      .bm-err { color: #c62828; font-size: 12px; margin: 4px 10px; }
    `,
  ],
})
export class PlanLibraryComponent implements AfterViewInit, OnDestroy {
  private planService = inject(PlanService);
  @ViewChild('editor') editorEl!: ElementRef<HTMLDivElement>;

  plans = signal<StoredPlan[]>([]);
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
    this.ed = monaco.editor.create(this.editorEl.nativeElement, {
      value: '', language: 'yaml', automaticLayout: true, minimap: { enabled: false },
      fontSize: 12, scrollBeyondLastLine: false,
      theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'vs-dark' : 'vs',
    });
    this.reload();
  }

  ngOnDestroy(): void { this.ed?.dispose(); }

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
    this.msg.set(null); this.saveErr.set(null);
    this.planService.document(p.prefix, p.name).subscribe({
      next: (d) => {
        this.doc.set(d);
        this.moveFolder = d.folder;
        this.fmt.set(d.source_format === 'yaml' ? 'yaml' : d.source_format === 'json' ? 'json' : 'nt');
        this.applyFmt();
      },
      error: (e) => this.saveErr.set(e?.error?.detail ?? 'failed to load document'),
    });
  }

  setFmt(f: Fmt): void { this.fmt.set(f); this.applyFmt(); }

  private applyFmt(): void {
    const d = this.doc();
    if (!d || !this.ed) return;
    const f = this.fmt();
    this.ed.setValue(d.formats[f] ?? '');
    const model = this.ed.getModel();
    if (model) monaco.editor.setModelLanguage(model, f === 'json' ? 'json' : 'yaml');
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
