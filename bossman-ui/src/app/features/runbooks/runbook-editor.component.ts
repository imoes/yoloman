import { AfterViewInit, Component, ElementRef, OnDestroy, OnInit, ViewChild, computed, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import * as monaco from 'monaco-editor';
import { environment } from '../../../environments/environment';
import { Agent } from '../../core/models/agent.model';
import { AgentService } from '../../core/services/agent.service';
import { DialogService } from '../../shared/dialogs/dialog.service';

// Monaco locally (no CDN). We lint server-side (/runbooks/lint), so Monaco's
// own language workers aren't needed — a no-op worker keeps the editor from
// erroring while still giving full editing + YAML highlighting + our markers.
(self as unknown as { MonacoEnvironment: unknown }).MonacoEnvironment = {
  getWorker() {
    return new Worker(URL.createObjectURL(new Blob(['self.onmessage=function(){}'], { type: 'text/javascript' })));
  },
};

interface StepResult { name: string; module: string; status: string; changed: boolean | null; item?: unknown; error?: string; }
interface RunResult {
  runbook?: string; check_mode?: boolean; ok?: boolean; changed?: boolean; aborted?: boolean;
  facts_gathered?: number; steps?: StepResult[];
}
interface LintResult { ok: boolean; kind?: string; name?: string; steps?: number; error?: string; line?: number; }
interface RunRow { id: string; runbook: string; status: string; dry_run: boolean; created_at: string; }
interface RbRow { kind: 'folder' | 'rb'; label: string; depth: number; path?: string; rb?: { id: string; name: string; kind: string; folder: string }; }

const STARTER = `name: web baseline
targets: group:web-servers
steps:
  -
    name: install nginx
    module: apt
    args:
      name: nginx
      state: present
  -
    name: reload if changed
    module: service
    when: dropped_config.changed
    args:
      name: nginx
      state: reloaded
`;

// Native fact names use the yoloman_ prefix (the agent also emits ansible_
// aliases for imported Ansible content, but these are what we advertise).
const MAGIC_VARS = [
  'inventory_hostname', 'yoloman_hostname', 'yoloman_distribution', 'yoloman_kernel',
  'yoloman_architecture', 'yoloman_memtotal_mb', 'yoloman_processor_vcpus',
  'yoloman_board_vendor', 'yoloman_board_name', 'yoloman_product_serial',
  'yoloman_system_vendor', 'yoloman_bios_vendor', 'yoloman_chassis_vendor',
  'inventory.system.serial_number', 'inventory.cpu.model', 'inventory.memory_mb',
  'inventory.os.pretty_name', 'inventory.disks', 'inventory.nics',
];

/**
 * Block G11 — Runbook editor. Monaco (local, no CDN) editing a NestedText
 * runbook with YAML highlighting; server-side lint (/runbooks/lint) surfaces
 * errors as Monaco markers at their line. Pick a host, dry-run (check_mode
 * preview) then apply. Magic variables (agent facts, incl. motherboard) are
 * listed for reference. Mirrors the ansible-manager YamlEditor solution:
 * value + server lintErrors→setModelMarkers.
 */
@Component({
  selector: 'app-runbook-editor',
  standalone: true,
  imports: [DatePipe, FormsModule, MatButtonModule, MatIconModule, MatFormFieldModule, MatInputModule, MatSelectModule],
  template: `
    <div class="bm-page">
      <div class="bm-header-row">
        <h1>Runbooks</h1>
        <span class="bm-subtitle">Author a NestedText runbook, lint it, dry-run against a host, then apply.</span>
      </div>

      <div class="bm-split">
        <aside class="bm-tree">
          <div class="bm-tree-head">
            <strong>Library</strong>
            <button mat-icon-button (click)="newRunbook()" title="New runbook"><mat-icon>note_add</mat-icon></button>
          </div>
          <ul>
            @for (row of rows(); track row.kind + (row.path || '') + (row.rb?.id || '')) {
              @if (row.kind === 'folder') {
                <li class="bm-fold" [style.padding-left.px]="8 + row.depth * 14" (click)="toggle(row.path!)">
                  <mat-icon>{{ expanded().has(row.path!) ? 'folder_open' : 'folder' }}</mat-icon>{{ row.label }}
                </li>
              } @else {
                <li class="bm-rb" [class.bm-sel]="currentId() === row.rb!.id" [style.padding-left.px]="8 + row.depth * 14" (click)="load(row.rb!.id)">
                  <mat-icon>{{ row.rb!.kind === 'role' ? 'assignment' : 'terminal' }}</mat-icon>{{ row.label }}
                </li>
              }
            }
            @if (!rows().length) { <li class="bm-dim" style="padding:8px">No saved runbooks.</li> }
          </ul>
        </aside>
        <div class="bm-left">
          <div class="bm-toolbar">
            <mat-form-field appearance="outline" class="bm-host">
              <mat-label>Folder</mat-label>
              <input matInput [(ngModel)]="moveFolder" placeholder="linux/base (empty = root)" />
            </mat-form-field>
            <button mat-stroked-button (click)="save()"><mat-icon>save</mat-icon> {{ currentId() ? 'Save' : 'Save as new' }}</button>
            @if (currentId()) { <button mat-button (click)="newRunbook()">New</button> }
            @if (saveMsg()) { <span class="bm-dim">{{ saveMsg() }}</span> }
          </div>
          <div #editor class="bm-editor"></div>
          <div class="bm-toolbar">
            <button mat-stroked-button (click)="doLint()"><mat-icon>check_circle</mat-icon> Lint</button>
            <mat-form-field appearance="outline" class="bm-host">
              <mat-label>Host</mat-label>
              <mat-select [ngModel]="hostId()" (ngModelChange)="onHostChange($event)">
                @for (h of hosts(); track h.id) { <mat-option [value]="h.id">{{ h.name }}</mat-option> }
              </mat-select>
            </mat-form-field>
            <button mat-stroked-button [disabled]="!hostId() || running()" (click)="run(true)">
              <mat-icon>preview</mat-icon> Dry run
            </button>
            <button mat-raised-button color="primary" [disabled]="!hostId() || running()" (click)="apply()">
              <mat-icon>play_arrow</mat-icon> Apply
            </button>
          </div>

          @if (lint(); as l) {
            <div class="bm-lint" [class.bm-ok]="l.ok" [class.bm-err]="!l.ok">
              @if (l.ok) { ✓ {{ l.kind }} “{{ l.name }}” — {{ l.steps }} step(s), valid. }
              @else { ✗ {{ l.error }}{{ l.line ? ' (line ' + l.line + ')' : '' }} }
            </div>
          }

          @if (result(); as r) {
            <div class="bm-result">
              <div class="bm-result-head">
                {{ r.check_mode ? 'Dry run' : 'Applied' }} — {{ r.runbook }} ·
                <span [class.bm-ok]="r.ok" [class.bm-err]="!r.ok">{{ r.ok ? 'ok' : (r.aborted ? 'aborted' : 'failed') }}</span>
                @if (r.changed) { · changed } · {{ r.facts_gathered }} facts
              </div>
              <table class="bm-steps">
                <tbody>
                  @for (s of r.steps || []; track $index) {
                    <tr>
                      <td><span class="bm-badge bm-{{ s.status }}">{{ s.status }}</span></td>
                      <td class="bm-mono">{{ s.name || s.module }}{{ s.item != null ? ' [' + s.item + ']' : '' }}</td>
                      <td class="bm-dim">{{ s.error }}</td>
                    </tr>
                  }
                </tbody>
              </table>
            </div>
          }
        </div>

        <div class="bm-right">
          <div class="bm-panel-title">Magic variables</div>
          <p class="bm-dim">Agent facts, available as <code>&#36;&#123;var&#125;</code> in args/when — no declaration:</p>
          <ul class="bm-vars">
            @for (v of magicVars; track v) { <li class="bm-mono">{{ ref(v) }}</li> }
          </ul>
          <p class="bm-dim">Also any host/group/OU var, role parameters, and <code>&#36;&#123;item&#125;</code> in a loop.</p>

          <div class="bm-panel-title" style="margin-top:16px;">Recent runs @if (hostId()) { <span class="bm-dim">· this host</span> }</div>
          @if (runs().length === 0) { <p class="bm-dim">No runs recorded yet.</p> }
          <ul class="bm-vars">
            @for (r of runs(); track r.id) {
              <li class="bm-run" (click)="viewRun(r.id)" title="View this run">
                <span class="bm-badge bm-{{ r.status }}">{{ r.status }}</span>
                <span class="bm-mono">{{ r.runbook }}</span>
                @if (r.dry_run) { <span class="bm-dim">· dry</span> }
                <span class="bm-dim">· {{ r.created_at | date:'MM-dd HH:mm' }}</span>
              </li>
            }
          </ul>
        </div>
      </div>
    </div>
  `,
  styles: [
    `
      .bm-page { padding: 24px; }
      .bm-header-row { display: flex; align-items: baseline; gap: 14px; }
      .bm-subtitle { opacity: 0.7; }
      .bm-split { display: flex; gap: 16px; margin-top: 12px; align-items: flex-start; }
      .bm-tree { flex: 0 0 220px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: auto; max-height: 560px; }
      .bm-tree-head { display: flex; align-items: center; justify-content: space-between; padding: 6px 8px 6px 12px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
      .bm-tree ul { list-style: none; margin: 0; padding: 4px 0; }
      .bm-tree li { display: flex; align-items: center; gap: 6px; padding: 5px 8px; cursor: pointer; font-size: 13px; }
      .bm-tree li mat-icon { font-size: 17px; width: 17px; height: 17px; opacity: 0.7; }
      .bm-fold { font-weight: 600; }
      .bm-rb:hover { background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent); }
      .bm-rb.bm-sel { background: color-mix(in srgb, var(--mat-sys-primary) 14%, transparent); }
      .bm-left { flex: 1 1 60%; min-width: 0; }
      .bm-right { flex: 1 1 30%; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 12px 14px; }
      .bm-editor { height: 460px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: hidden; }
      .bm-toolbar { display: flex; align-items: center; gap: 10px; margin: 10px 0; flex-wrap: wrap; }
      .bm-host { width: 220px; }
      .bm-lint { padding: 8px 12px; border-radius: 6px; font-size: 13px; }
      .bm-lint.bm-ok { background: color-mix(in srgb, var(--bm-green) 16%, transparent); }
      .bm-lint.bm-err { background: color-mix(in srgb, var(--bm-red) 18%, transparent); }
      .bm-result { margin-top: 12px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 10px 12px; }
      .bm-result-head { margin-bottom: 6px; }
      .bm-steps { width: 100%; border-collapse: collapse; }
      .bm-steps td { padding: 3px 10px 3px 0; border-top: 1px solid var(--mat-sys-outline-variant); vertical-align: top; }
      .bm-badge { font-size: 11px; padding: 1px 7px; border-radius: 999px; }
      .bm-ok { color: var(--bm-green); } .bm-err { color: var(--bm-red); }
      .bm-badge.bm-changed { background: color-mix(in srgb, var(--bm-gold, #caa300) 26%, transparent); }
      .bm-badge.bm-ok { background: color-mix(in srgb, var(--bm-green) 20%, transparent); }
      .bm-badge.bm-failed { background: color-mix(in srgb, var(--bm-red) 22%, transparent); }
      .bm-badge.bm-skipped { background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
      .bm-badge.bm-aborted { background: color-mix(in srgb, var(--bm-red) 22%, transparent); }
      .bm-run { padding: 3px 0; cursor: pointer; display: flex; gap: 6px; align-items: center; }
      .bm-run:hover { opacity: 0.8; }
      .bm-mono { font-family: monospace; }
      .bm-dim { opacity: 0.6; font-size: 12.5px; }
      .bm-panel-title { font-weight: 600; margin-bottom: 6px; }
      .bm-vars { list-style: none; padding: 0; margin: 6px 0; font-size: 12.5px; }
      .bm-vars li { padding: 1px 0; }
    `,
  ],
})
export class RunbookEditorComponent implements OnInit, AfterViewInit, OnDestroy {
  private http = inject(HttpClient);
  private agentService = inject(AgentService);
  private dialog = inject(DialogService);
  private base = environment.apiUrl;
  @ViewChild('editor') editorEl!: ElementRef<HTMLDivElement>;
  private ed?: monaco.editor.IStandaloneCodeEditor;

  hosts = signal<Agent[]>([]);
  hostId = signal<string>('');
  lint = signal<LintResult | null>(null);
  result = signal<RunResult | null>(null);
  running = signal(false);
  saved = signal<{ id: string; name: string; kind: string; folder: string }[]>([]);
  currentId = signal<string>('');
  saveMsg = signal<string>('');
  runs = signal<RunRow[]>([]);
  magicVars = MAGIC_VARS;
  // Library folder tree (mirrors Plan library): runbooks grouped by `folder`.
  expanded = signal<Set<string>>(new Set(['']));
  moveFolder = ''; // folder the current runbook is saved into

  /** Flatten runbooks into an indented folder tree honoring the expanded set. */
  rows = computed<RbRow[]>(() => {
    const byFolder = new Map<string, { id: string; name: string; kind: string; folder: string }[]>();
    for (const r of this.saved()) {
      const f = r.folder || '';
      (byFolder.get(f) ?? byFolder.set(f, []).get(f)!).push(r);
    }
    const folders = new Set<string>(['']);
    for (const f of byFolder.keys()) {
      const segs = f ? f.split('/') : [];
      for (let i = 0; i <= segs.length; i++) folders.add(segs.slice(0, i).join('/'));
    }
    const childFolders = (parent: string) =>
      [...folders].filter((f) => f && (parent ? f.startsWith(parent + '/') : true) &&
        f.split('/').length === (parent ? parent.split('/').length + 1 : 1)).sort();
    const out: RbRow[] = [];
    const walk = (folder: string, depth: number) => {
      for (const cf of childFolders(folder)) {
        out.push({ kind: 'folder', label: cf.split('/').pop()!, depth, path: cf });
        if (this.expanded().has(cf)) walk(cf, depth + 1);
      }
      for (const rb of (byFolder.get(folder) ?? []).sort((a, b) => a.name.localeCompare(b.name))) {
        out.push({ kind: 'rb', label: rb.name, depth, rb });
      }
    };
    walk('', 0);
    return out;
  });

  ngOnInit(): void {
    this.agentService.list().subscribe((a) => this.hosts.set(a));
    this.reloadList();
    this.loadRuns();
  }

  private loadRuns(): void {
    const q = this.hostId() ? `?agent_id=${this.hostId()}` : '';
    this.http.get<{ runs: RunRow[] }>(`${this.base}/runbook-runs${q}`).subscribe((r) => this.runs.set(r.runs));
  }

  viewRun(id: string): void {
    this.http.get<{ runbook: string; result: RunResult }>(`${this.base}/runbook-runs/${id}`)
      .subscribe((r) => this.result.set({ ...r.result, runbook: r.runbook }));
  }

  onHostChange(id: string): void {
    this.hostId.set(id);
    this.loadRuns();
  }

  private reloadList(): void {
    this.http.get<{ runbooks: { id: string; name: string; kind: string; folder: string }[] }>(`${this.base}/runbooks`)
      .subscribe((r) => this.saved.set(r.runbooks));
  }

  toggle(path: string): void {
    const s = new Set(this.expanded());
    s.has(path) ? s.delete(path) : s.add(path);
    this.expanded.set(s);
  }

  load(id: string): void {
    this.currentId.set(id);
    this.saveMsg.set('');
    if (!id) { this.ed?.setValue(STARTER); this.moveFolder = ''; return; }
    this.http.get<{ nt: string; folder: string }>(`${this.base}/runbooks/${id}`).subscribe((r) => {
      this.ed?.setValue(r.nt || '');
      this.moveFolder = r.folder || '';
    });
  }

  newRunbook(): void {
    this.currentId.set('');
    this.saveMsg.set('');
    this.moveFolder = '';
    this.ed?.setValue(STARTER);
  }

  save(): void {
    const nt = this.source();
    const id = this.currentId();
    const folder = this.moveFolder.trim().replace(/^\/+|\/+$/g, '');
    const req = id
      ? this.http.put<{ id: string; name: string; folder: string }>(`${this.base}/runbooks/${id}`, { nt, folder })
      : this.http.post<{ id: string; name: string; folder: string }>(`${this.base}/runbooks`, { nt, folder });
    req.subscribe({
      next: (r) => { this.currentId.set(r.id); this.saveMsg.set('saved: ' + r.name); this.reloadList(); },
      error: (e) => this.saveMsg.set('save failed: ' + (e?.error?.detail ?? 'error')),
    });
  }

  ngAfterViewInit(): void {
    const dark = matchMedia('(prefers-color-scheme: dark)').matches;
    this.ed = monaco.editor.create(this.editorEl.nativeElement, {
      value: STARTER,
      language: 'yaml', // NestedText highlights well as YAML; validation is server-side
      theme: dark ? 'vs-dark' : 'vs',
      minimap: { enabled: false },
      automaticLayout: true,
      tabSize: 2,
      fontSize: 13,
      scrollBeyondLastLine: false,
    });
    this.ed.onDidChangeModelContent(() => this.lint.set(null));
  }

  ngOnDestroy(): void {
    this.ed?.dispose();
  }

  private source(): string {
    return this.ed?.getValue() ?? '';
  }

  private setMarkers(l: LintResult): void {
    const model = this.ed?.getModel();
    if (!model) return;
    const markers = !l.ok
      ? [{
          startLineNumber: l.line || 1, startColumn: 1,
          endLineNumber: l.line || 1, endColumn: model.getLineMaxColumn(l.line || 1),
          message: l.error || 'invalid', severity: monaco.MarkerSeverity.Error,
        }]
      : [];
    monaco.editor.setModelMarkers(model, 'runbook-lint', markers);
  }

  doLint(): void {
    this.http.post<LintResult>(`${this.base}/runbooks/lint`, { nt: this.source() }).subscribe({
      next: (r) => { this.lint.set(r); this.setMarkers(r); },
      error: (e) => { const l = { ok: false, error: e?.error?.detail ?? 'lint failed' }; this.lint.set(l); this.setMarkers(l); },
    });
  }

  run(dryRun: boolean): void {
    this.running.set(true);
    this.result.set(null);
    this.http.post<RunResult>(`${this.base}/agents/${this.hostId()}/runbook/run`, { nt: this.source(), dry_run: dryRun }).subscribe({
      next: (r) => { this.result.set(r); this.running.set(false); this.loadRuns(); },
      error: (e) => {
        this.result.set({ ok: false, steps: [{ name: 'error', module: '', status: 'failed', changed: null, error: e?.error?.detail ?? 'run failed' }] });
        this.running.set(false);
      },
    });
  }

  async apply(): Promise<void> {
    if (await this.dialog.confirm({ title: 'Apply runbook', message: 'Apply this runbook for real (not a dry run)?', confirmText: 'Apply', danger: true })) {
      this.run(false);
    }
  }

  /** Render a magic-variable reference like ${yoloman_hostname} without
   * colliding with Angular's {{ }} interpolation. */
  ref(v: string): string {
    return '$' + '{' + v + '}';
  }
}
