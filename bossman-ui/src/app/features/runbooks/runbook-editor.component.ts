import { AfterViewInit, Component, ElementRef, OnDestroy, OnInit, ViewChild, computed, effect, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import * as monaco from 'monaco-editor';
import { SequentialWorkflowDesignerModule } from 'sequential-workflow-designer-angular';
import { Definition, Step, StepsConfiguration, ToolboxConfiguration } from 'sequential-workflow-designer';
import { environment } from '../../../environments/environment';
import { Agent } from '../../core/models/agent.model';
import { ModuleOptionSpec } from '../../core/models/module.model';
import { AgentService } from '../../core/services/agent.service';
import { ModuleService } from '../../core/services/module.service';
import { DialogService } from '../../shared/dialogs/dialog.service';
import { ParamFormComponent } from '../../shared/param-form/param-form.component';
import { ParamSchema } from '../../shared/param-form/param-form.types';
import * as Blockly from 'blockly';
import { BlocklyWorkspaceComponent } from './blockly/blockly-workspace.component';
import { registerRunbookBlocks } from './blockly/blocks';
import { buildRunbookToolbox } from './blockly/toolbox';
import { workspaceToSteps } from './blockly/generator';
import { stepsToWorkspace } from './blockly/importer';
import { ArgFieldSpec, configureArgspec, notifyArgspec } from './blockly/argspec-bridge';

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
interface DocStep { name?: string; module: string; args?: Record<string, unknown>; when?: string; loop?: unknown; register?: string; ignore_errors?: boolean; }
interface RunbookDoc { kind: string; name: string; targets?: string | null; parameters?: ParamSchema; steps?: DocStep[]; }
interface LintResult { ok: boolean; kind?: string; name?: string; steps?: number; error?: string; line?: number; parameters?: ParamSchema; doc?: RunbookDoc; }
interface RunRow { id: string; runbook: string; status: string; dry_run: boolean; created_at: string; }
interface RbRow { kind: 'folder' | 'rb'; label: string; depth: number; path?: string; rb?: { id: string; name: string; kind: string; folder: string } }
interface ArgField { key: string; spec: ModuleOptionSpec; }

// F-10 visual builder helpers. A toolbox step is a plain SWD task; each maps
// 1:1 to a fleet NestedText runbook step on serialize.
let vuidCounter = 0;
function vtask(type: string, name: string, properties: Record<string, unknown>): Step {
  vuidCounter += 1;
  return { id: 'vstep-' + vuidCounter, componentType: 'task', type, name, properties } as Step;
}

function safeJson(s: string | undefined): Record<string, unknown> {
  if (!s) return {};
  try {
    const v = JSON.parse(s);
    return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

/** Serialize a params object as indented NestedText (the fleet runbook format:
 * `key: value`, nested dicts indented, arrays as `- item`). Handles the common
 * flat string-map args plus one level of nesting / scalar lists. */
function ntBlock(obj: Record<string, unknown>, indent: number): string {
  const pad = ' '.repeat(indent);
  const out: string[] = [];
  for (const [k, v] of Object.entries(obj || {})) {
    if (Array.isArray(v)) {
      out.push(`${pad}${k}:`);
      for (const item of v) out.push(`${pad}  - ${item}`);
    } else if (v && typeof v === 'object') {
      out.push(`${pad}${k}:`);
      out.push(ntBlock(v as Record<string, unknown>, indent + 2));
    } else {
      out.push(`${pad}${k}: ${v}`);
    }
  }
  return out.join('\n');
}

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
 * Block G11 — the Workflow designer. Two synced views of one runbook:
 * Monaco (NestedText, YAML-highlighted, server-side lint markers) and a
 * drag-and-drop canvas (sequential-workflow-designer). The round-trip is real:
 * text→visual parses via /runbooks/lint (which returns the canonical doc),
 * visual→text serialises to NestedText. A step's args are edited through a
 * form generated from the module's argspec (choices→select, description under
 * each field, defaults as placeholders) — raw JSON only as a fallback. A
 * runbook's typed `parameters` render as an input mask before dry-run/apply.
 */
@Component({
  selector: 'app-runbook-editor',
  standalone: true,
  imports: [DatePipe, FormsModule, MatButtonModule, MatIconModule, MatFormFieldModule, MatInputModule, MatSelectModule, SequentialWorkflowDesignerModule, ParamFormComponent, BlocklyWorkspaceComponent],
  template: `
    <div class="bm-page">
      <div class="bm-header-row">
        <h1>Workflow designer</h1>
        <span class="bm-subtitle">Author a runbook — drag modules on the canvas or edit NestedText — lint it, dry-run against a host, then apply.</span>
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
            <mat-form-field appearance="outline" class="bm-host" subscriptSizing="dynamic">
              <mat-label>Folder</mat-label>
              <input matInput [(ngModel)]="moveFolder" placeholder="linux/base (empty = root)" />
            </mat-form-field>
            <button mat-stroked-button (click)="save()"><mat-icon>save</mat-icon> {{ currentId() ? 'Save' : 'Save as new' }}</button>
            @if (currentId()) { <button mat-button (click)="newRunbook()">New</button> }
            <span class="bm-mode">
              <button mat-button [class.bm-mode-on]="mode() === 'text'" (click)="setMode('text')">
                <mat-icon>code</mat-icon> Text
              </button>
              <button mat-button [class.bm-mode-on]="mode() === 'visual'" (click)="setMode('visual')">
                <mat-icon>account_tree</mat-icon> Visual
              </button>
            </span>
            @if (saveMsg()) { <span class="bm-dim">{{ saveMsg() }}</span> }
          </div>

          @if (mode() === 'visual') {
            <div class="bm-vbar">
              <mat-form-field appearance="outline" class="bm-host" subscriptSizing="dynamic">
                <mat-label>Name</mat-label>
                <input matInput [(ngModel)]="visualName" (ngModelChange)="syncVisual()" />
              </mat-form-field>
              <mat-form-field appearance="outline" class="bm-host" subscriptSizing="dynamic">
                <mat-label>Targets</mat-label>
                <input matInput [(ngModel)]="visualTargets" (ngModelChange)="syncVisual()" placeholder="group:web-servers" />
              </mat-form-field>
              <span class="bm-dim">Build the runbook from blocks — pick a step from the toolbox, fill its fields; the NestedText stays in sync. Switch to Text any time.</span>
            </div>
            <div class="bm-canvas-row">
              @if (visualReady()) {
                <app-blockly-workspace class="bm-designer"
                  [toolbox]="blocklyToolbox"
                  (ready)="onBlocklyReady($event)"
                  (workspaceChange)="onBlocklyChange()"
                ></app-blockly-workspace>
              } @else {
                <div class="bm-designer bm-designer-loading"><span class="bm-dim">Preparing canvas…</span></div>
              }
            </div>
          }
          <div #editor class="bm-editor" [style.display]="mode() === 'text' ? 'block' : 'none'"></div>

          @if (paramMask(); as pm) {
            <div class="bm-params">
              <div class="bm-panel-title">Runbook parameters</div>
              <p class="bm-dim">This runbook declares typed parameters — fill them in (defaults shown), they are passed as variables on dry-run/apply.</p>
              <app-param-form [params]="pm" (valuesChange)="runVars = $event" />
            </div>
          }

          <div class="bm-toolbar">
            <button mat-stroked-button (click)="doLint()"><mat-icon>check_circle</mat-icon> Lint</button>
            <mat-form-field appearance="outline" class="bm-host" subscriptSizing="dynamic">
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

        <!-- Hidden in visual mode: the canvas needs the width (a squeezed
             designer falls into its cramped mobile layout). -->
        <div class="bm-right" [style.display]="mode() === 'visual' ? 'none' : 'block'">
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
      .bm-tree { flex: 0 0 220px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: auto; max-height: 620px; }
      .bm-tree-head { display: flex; align-items: center; justify-content: space-between; padding: 6px 8px 6px 12px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
      .bm-tree ul { list-style: none; margin: 0; padding: 4px 0; }
      .bm-tree li { display: flex; align-items: center; gap: 6px; padding: 5px 8px; cursor: pointer; font-size: 13px; }
      .bm-tree li mat-icon { font-size: 17px; width: 17px; height: 17px; opacity: 0.7; }
      .bm-fold { font-weight: 600; }
      .bm-rb:hover { background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent); }
      .bm-rb.bm-sel { background: color-mix(in srgb, var(--mat-sys-primary) 14%, transparent); }
      .bm-left { flex: 1 1 60%; min-width: 0; }
      .bm-right { flex: 1 1 30%; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 12px 14px; }
      .bm-editor { height: 520px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: hidden; }
      .bm-mode { display: inline-flex; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: hidden; margin-left: auto; }
      .bm-mode button { border-radius: 0; }
      .bm-mode-on { background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent); font-weight: 600; }
      .bm-vbar { display: flex; align-items: center; gap: 12px; margin-bottom: 8px; flex-wrap: wrap; }
      .bm-canvas-row { display: block; margin-bottom: 10px; }
      .bm-palette { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; height: 560px; display: flex; flex-direction: column; }
      .bm-palette-search { margin: 8px; padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font-size: 13px; }
      .bm-palette-list { flex: 1; overflow-y: auto; padding: 0 4px; }
      .bm-palette-item { display: flex; flex-direction: column; align-items: flex-start; gap: 1px; width: 100%; text-align: left;
        background: none; border: none; border-left: 3px solid transparent; color: inherit; cursor: pointer; padding: 5px 8px; border-radius: 0 6px 6px 0; }
      .bm-palette-item:hover { background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); border-left-color: var(--mat-sys-primary); }
      .bm-palette-item .bm-mono { font-size: 12.5px; }
      .bm-palette-desc { font-size: 11px; opacity: 0.55; line-height: 1.25; }
      .bm-palette-hint { padding: 6px 8px; margin: 0; border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-designer { display: block; height: 560px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: hidden; min-width: 0; }
      .bm-designer-loading { display: flex; align-items: center; justify-content: center; }
      /* The Angular wrapper nests <div class="sqd-designer-angular"><div
         class="sqd-designer"> with no height of their own — without both at
         100% the workspace collapses to a ~107px strip hidden behind the
         toolbox and steps look invisible/unclickable. */
      .bm-designer ::ng-deep .sqd-designer-angular { height: 100%; }
      .bm-designer ::ng-deep .sqd-designer { height: 100%; }
      /* Our own palette replaces the built-in toolbox (which overlaid the steps
         and duplicated the module list). */
      .bm-designer ::ng-deep .sqd-toolbox { display: none; }
      .bm-veditor { padding: 10px; display: flex; flex-direction: column; gap: 8px; width: 320px; max-height: 520px; overflow-y: auto; }
      .bm-veditor h4 { margin: 0 0 2px; }
      .bm-veditor label { display: flex; flex-direction: column; font-size: 12px; gap: 3px; }
      .bm-veditor input, .bm-veditor textarea, .bm-veditor select {
        padding: 4px 6px; font-family: monospace; font-size: 12px;
        background: var(--mat-sys-surface); color: var(--mat-sys-on-surface);
        border: 1px solid var(--mat-sys-outline-variant); border-radius: 4px;
      }
      .bm-arg-h { font-size: 11px; text-transform: uppercase; letter-spacing: .04em; opacity: 0.55; margin-top: 6px; }
      .bm-arg-desc { font-size: 11px; opacity: 0.6; font-family: system-ui, sans-serif; line-height: 1.35; }
      .bm-req { color: var(--bm-red, #c62828); }
      .bm-arg-raw summary { font-size: 12px; opacity: 0.7; cursor: pointer; }
      .bm-arg-raw textarea { width: 100%; box-sizing: border-box; margin-top: 4px; }
      .bm-arg-check { flex-direction: row !important; align-items: center; gap: 6px !important; }
      .bm-params { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 12px 14px; margin-top: 10px; }
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
  private moduleService = inject(ModuleService);
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

  // The runbook's typed parameter mask (visible params only) — filled from the
  // lint response; the form's values are passed as run variables.
  runVars: Record<string, unknown> = {};
  paramMask = computed<ParamSchema | null>(() => {
    const p = this.lint()?.parameters ?? null;
    if (!p) return null;
    const visible = Object.fromEntries(Object.entries(p).filter(([, s]) => s && typeof s === 'object' && 'type' in s && !s.hidden));
    return Object.keys(visible).length ? (visible as ParamSchema) : null;
  });

  // F-10: visual authoring mode, now ROUND-TRIP: text→visual parses the current
  // NestedText via /runbooks/lint (which returns the canonical doc); visual→text
  // serialises back into Monaco (the single source lint/dry-run/apply read).
  mode = signal<'text' | 'visual'>('text');
  // The designer measures its workspace at init — instantiate it one tick AFTER
  // the visual layout settles, or it caches a tiny pre-layout size (steps end up
  // in a 180px strip behind the toolbox).
  visualReady = signal(false);
  visualName = 'my-runbook';
  visualTargets = '';
  // Blockly visual designer (replaces sequential-workflow-designer). The canvas
  // owns block editing; we only walk it to steps → NestedText and back.
  blocklyToolbox = buildRunbookToolbox();
  private blocklyWs?: Blockly.WorkspaceSvg;
  private pendingSteps: DocStep[] | null = null;
  definition: Definition = { sequence: [], properties: {} };
  toolbox: ToolboxConfiguration = {
    groups: [{
      name: 'Flow',
      steps: [
        vtask('module', 'module (any)', { module: '', args: {} }),
        vtask('module', 'shell command', { module: 'shell', args: { cmd: '' } }),
        vtask('module', 'config template', { module: 'config_template', args: { template: '', dest: '' } }),
        vtask('set_fact', 'set_fact', { facts: '{}' }),
        vtask('debug', 'debug', { msg: '' }),
      ],
    }],
  };
  stepsConfig: StepsConfiguration = { iconUrlProvider: () => null };

  // ---- module catalog: the palette, fqcn lookup, argspec cache ----
  private fqcnByName = new Map<string, string>();
  private descByModule = new Map<string, string>();
  moduleNames = signal<string[]>([]);
  private argspecCache = signal<Record<string, ArgField[]>>({});
  private argspecPending = new Set<string>();

  /** Synchronous argspec read for the Blockly blocks (argspec-bridge). Maps the
   * editor's cached ArgField[] to the bridge's ArgFieldSpec[]. */
  private argspecProvider = (module: string): ArgFieldSpec[] | undefined => {
    const cached = this.argspecCache()[module];
    if (!cached) return undefined;
    return cached.map((f) => ({
      key: f.key,
      type: f.spec.type,
      required: f.spec.required,
      choices: (f.spec.choices as unknown[]) ?? undefined,
      default: f.spec.default,
      description: this.descText(f.spec.description),
    }));
  };

  constructor() {
    // When an argspec finishes loading (cache updates), tell the Blockly bridge so
    // any block waiting on that module upgrades its fields to typed dropdowns/
    // checkboxes. notifyArgspec is idempotent, so re-notifying cached keys is free.
    effect(() => {
      const cache = this.argspecCache();
      for (const key of Object.keys(cache)) notifyArgspec(key);
    });
  }

  // Blockly-style palette: search over the whole catalog, click to place.
  // The Flow entries (shell/config template/set_fact/debug) sit on top.
  private static readonly FLOW_ITEMS = [
    { ref: 'shell', name: 'shell command', desc: 'Run a shell command on the host', collection: 'flow', kind: 'module' as const },
    { ref: 'config_template', name: 'config template', desc: 'Render a config template to a file', collection: 'flow', kind: 'module' as const },
    { ref: 'set_fact', name: 'set_fact', desc: 'Set variables for later steps', collection: 'flow', kind: 'set_fact' as const },
    { ref: 'debug', name: 'debug', desc: 'Print a message (with variables)', collection: 'flow', kind: 'debug' as const },
  ];
  paletteQuery = signal('');
  private paletteAll = signal<{ ref: string; name: string; desc: string; collection: string; kind?: 'module' | 'set_fact' | 'debug' }[]>([]);
  paletteHits = computed(() => {
    const q = this.paletteQuery().trim().toLowerCase();
    const all = [...RunbookEditorComponent.FLOW_ITEMS, ...this.paletteAll()];
    const hits = q
      ? all.filter((m) => m.name.toLowerCase().includes(q) || m.ref.toLowerCase().includes(q) || m.desc.toLowerCase().includes(q))
      : all;
    return hits.slice(0, 60);
  });

  /** Load the module catalog into the click-to-place palette (searchable across
   * ALL modules) and the fqcn/description lookups. The SWD toolbox keeps only
   * the small Flow group — dragging 2000 modules was unusable. */
  private buildToolbox(): void {
    this.moduleService.catalog().subscribe((cat) => {
      const palette: { ref: string; name: string; desc: string; collection: string }[] = [];
      const names: string[] = [];
      for (const m of cat.modules) {
        if (m.fqcn.startsWith('checkmk.')) continue; // checks, not runbook modules
        const builtin = m.collection === 'ansible.builtin' || m.collection === 'built-in';
        const moduleRef = builtin ? m.name : m.fqcn;
        this.fqcnByName.set(m.name, m.fqcn);
        if (m.short_description) this.descByModule.set(moduleRef, m.short_description);
        names.push(moduleRef);
        palette.push({ ref: moduleRef, name: m.name, desc: m.short_description ?? '', collection: m.collection });
      }
      palette.sort((a, b) => a.name.localeCompare(b.name));
      this.paletteAll.set(palette);
      this.moduleNames.set(names.sort());
    });
  }

  /** Click-to-place: append the module as a new step and sync the text. The
   * user then clicks the step on the canvas to fill in its parameters. */
  addModuleStep(m: { ref: string; name: string; kind?: 'module' | 'set_fact' | 'debug' }): void {
    let step: Step;
    if (m.kind === 'set_fact') step = vtask('set_fact', 'set_fact', { facts: '{}' });
    else if (m.kind === 'debug') step = vtask('debug', 'debug', { msg: '' });
    else step = vtask('module', m.name, { module: m.ref, args: {} });
    this.definition = { sequence: [...(this.definition.sequence as Step[]), step], properties: this.definition.properties };
    this.syncVisual();
  }

  // ---- per-step argspec form ----
  argModule(step: Step): string {
    return String((step.properties as Record<string, unknown>)['module'] ?? '');
  }
  moduleDesc(module: string): string {
    return this.descByModule.get(module) ?? '';
  }
  argspecLoaded(module: string): boolean {
    return module in this.argspecCache();
  }
  /** The module's declared options (cached; fetched lazily on first render).
   * Catalog (Starlark collection) modules come from the module detail; NATIVE
   * Go modules (apt, service, file, …) aren't in the catalog — their schema is
   * fetched from a host's GET /agents/{id}/tools (input_schema). */
  argFields(module: string): ArgField[] {
    if (!module) return [];
    const cached = this.argspecCache()[module];
    if (cached) return cached;
    if (!this.argspecPending.has(module)) {
      this.argspecPending.add(module);
      const fqcn = module.includes('.') ? module : (this.fqcnByName.get(module) ?? module);
      this.moduleService.detail(fqcn).subscribe({
        next: (d) => {
          const fields = Object.entries(d.metadata.options ?? {}).map(([key, spec]) => ({ key, spec }));
          if (!fields.length) { this.agentSchemaFields(module); return; }
          // Required options first, then alphabetical — the form reads top-down.
          fields.sort((a, b) => Number(!!b.spec.required) - Number(!!a.spec.required) || a.key.localeCompare(b.key));
          if (d.metadata.short_description) this.descByModule.set(module, d.metadata.short_description);
          this.argspecCache.update((m) => ({ ...m, [module]: fields }));
        },
        error: () => this.agentSchemaFields(module),
      });
    }
    return [];
  }

  // name -> {description, input_schema} from a live agent's tool list; loaded
  // once per editor session (native modules are the same on every agent).
  private agentTools: Record<string, { description?: string; input_schema?: { properties?: Record<string, Record<string, unknown>>; required?: string[] } }> | null = null;
  private agentToolsLoading = false;
  private agentToolsWaiters: string[] = [];

  /** A host we can actually reach for native-module schemas: the selected one if
   * it has an address, else the first agent WITH a non-null address. Skips
   * address-less agents (the canvas/demo + satellites) whose /tools 422s
   * ("no reachable address") — which left native modules (apt/service/…) stuck
   * as plain text fields instead of typed dropdowns. */
  private schemaHostId(): string {
    const byId = (id: string) => this.hosts().find((h) => h.id === id);
    const sel = this.hostId() ? byId(this.hostId()) : undefined;
    if (sel?.address) return sel.id;
    return this.hosts().find((h) => h.address)?.id ?? '';
  }

  /** Resolve a native module's options from an agent's tool schema. */
  private agentSchemaFields(module: string): void {
    if (this.agentTools) { this.finishAgentSchema(module); return; }
    this.agentToolsWaiters.push(module);
    if (this.agentToolsLoading) return;
    const hid = this.schemaHostId();
    if (!hid) { this.argspecCache.update((m) => ({ ...m, [module]: [] })); return; }
    this.agentToolsLoading = true;
    this.http.get<{ tools: { name: string; description?: string; input_schema?: { properties?: Record<string, Record<string, unknown>>; required?: string[] } }[] }>(
      `${this.base}/agents/${hid}/tools`,
    ).subscribe({
      next: (r) => {
        this.agentTools = Object.fromEntries((r.tools || []).map((t) => [t.name, t]));
        for (const w of this.agentToolsWaiters) this.finishAgentSchema(w);
        this.agentToolsWaiters = [];
      },
      error: () => {
        this.agentTools = {};
        for (const w of this.agentToolsWaiters) this.argspecCache.update((m) => ({ ...m, [w]: [] }));
        this.agentToolsWaiters = [];
      },
    });
  }

  private finishAgentSchema(module: string): void {
    const tool = this.agentTools?.[module];
    const schema = tool?.input_schema;
    const required = new Set(schema?.required ?? []);
    const fields: ArgField[] = Object.entries(schema?.properties ?? {}).map(([key, s]) => ({
      key,
      spec: {
        type: (s['type'] as string) ?? 'str',
        description: this.descText(s['description']),
        choices: (s['enum'] as unknown[]) ?? undefined,
        default: s['default'],
        required: required.has(key),
      } as ModuleOptionSpec,
    }));
    fields.sort((a, b) => Number(!!b.spec.required) - Number(!!a.spec.required) || a.key.localeCompare(b.key));
    if (tool?.description && !this.descByModule.has(module)) {
      // Native descriptions are long-form — keep the first sentence for the header.
      this.descByModule.set(module, tool.description.split(/\.\s/)[0].slice(0, 160));
    }
    this.argspecCache.update((m) => ({ ...m, [module]: fields }));
  }
  private stepArgs(step: Step): Record<string, unknown> {
    const p = step.properties as Record<string, unknown>;
    const raw = p['args'];
    if (typeof raw === 'string') { p['args'] = safeJson(raw); return p['args'] as Record<string, unknown>; }
    if (!raw || typeof raw !== 'object') { p['args'] = {}; }
    return p['args'] as Record<string, unknown>;
  }
  argValue(step: Step, key: string): string {
    const v = this.stepArgs(step)[key];
    return v === undefined || v === null ? '' : (typeof v === 'object' ? JSON.stringify(v) : String(v));
  }
  setArg(step: Step, key: string, value: string, editor: { context: { notifyPropertiesChanged(): void } }): void {
    const args = this.stepArgs(step);
    if (value === '') delete args[key];
    else args[key] = value;
    editor.context.notifyPropertiesChanged();
    this.syncVisual();
  }
  argJson(step: Step): string {
    return JSON.stringify(this.stepArgs(step), null, 1);
  }
  setArgJson(step: Step, value: string, editor: { context: { notifyPropertiesChanged(): void } }): void {
    try {
      const v = JSON.parse(value);
      if (v && typeof v === 'object' && !Array.isArray(v)) {
        (step.properties as Record<string, unknown>)['args'] = v;
        editor.context.notifyPropertiesChanged();
        this.syncVisual();
      }
    } catch { /* ignore until the JSON is valid */ }
  }
  argPlaceholder(spec: ModuleOptionSpec): string {
    const parts: string[] = [];
    if (spec.type) parts.push(String(spec.type));
    if (spec.default !== undefined && spec.default !== null) parts.push(`default: ${spec.default}`);
    return parts.join(' · ');
  }
  descText(d: unknown): string {
    return Array.isArray(d) ? d.join(' ') : String(d ?? '');
  }

  /** Switch views. text→visual round-trips through the linter (canonical doc);
   * an invalid document keeps you in text mode with the error marked. */
  setMode(m: 'text' | 'visual'): void {
    // Any mode switch disposes/recreates the Blockly canvas — drop the stale
    // workspace ref so a pending import can't hit a disposed ("headless")
    // workspace. The freshly-mounted canvas re-sets it via onBlocklyReady.
    this.blocklyWs = undefined;
    if (m === 'visual') {
      this.http.post<LintResult>(`${this.base}/runbooks/lint`, { nt: this.source() }).subscribe({
        next: (r) => {
          this.lint.set(r);
          this.setMarkers(r);
          if (!r.ok) return; // stay in text mode; the error is marked
          if (r.doc?.kind === 'role') { this.lint.set({ ok: false, error: 'roles are edited as text (visual mode covers runbooks)' }); return; }
          if (r.doc) this.visualFromDoc(r.doc);
          this.mode.set('visual');
          this.visualReady.set(false);
          setTimeout(() => this.visualReady.set(true), 60);
        },
        error: () => { this.lint.set({ ok: false, error: 'lint failed' }); },
      });
      return;
    }
    this.mode.set(m);
    // Monaco mis-measures while display:none; relayout once it's visible again.
    setTimeout(() => this.ed?.layout(), 0);
  }

  /** Build the visual canvas from the canonical parsed doc (text→visual). The
   * workspace may not exist yet (the child renders one tick later), so stash the
   * steps and import them on (ready). */
  private visualFromDoc(doc: RunbookDoc): void {
    this.visualName = doc.name || 'my-runbook';
    this.visualTargets = doc.targets || '';
    this.pendingSteps = (doc.steps ?? []) as DocStep[];
    if (this.blocklyWs) this.importSteps();
  }

  /** Serialize the Blockly workspace into the NestedText runbook and write it
   * into Monaco, so lint/dry-run/apply/save (all read source()) stay unchanged.
   * Also called when the Name/Targets fields change. */
  syncVisual(): void {
    if (!this.blocklyWs) return;
    const steps = workspaceToSteps(this.blocklyWs);
    this.ed?.setValue(this.stepsToNt(steps));
  }

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
    registerRunbookBlocks();   // define the Blockly runbook blocks once
    // Blocks read argspec synchronously; the loader triggers the same lazy fetch
    // the SWD step-editor used (argFields), and the constructor's effect notifies
    // the bridge when it lands.
    configureArgspec(this.argspecProvider, (module) => { this.argFields(module); });
    this.agentService.list().subscribe((a) => this.hosts.set(a));
    this.reloadList();
    this.loadRuns();
    this.buildToolbox();
  }

  // ---- Blockly visual designer wiring ----
  onBlocklyReady(ws: Blockly.WorkspaceSvg): void {
    this.blocklyWs = ws;
    if (this.pendingSteps) this.importSteps();
  }
  onBlocklyChange(): void {
    this.syncVisual();
  }
  /** Load the current runbook's steps into the workspace without echoing the
   * import back as edits (events off → no change emit → no text rewrite). */
  private importSteps(): void {
    if (!this.blocklyWs) return;
    Blockly.Events.disable();
    try {
      stepsToWorkspace(this.blocklyWs, this.pendingSteps ?? []);
    } finally {
      Blockly.Events.enable();
    }
  }
  /** blocks → DocStep[] → NestedText, mirroring the old SWD serialization
   * exactly so lint/dry-run/apply/save (all read source()) are unaffected. */
  private stepsToNt(steps: DocStep[]): string {
    const lines: string[] = [`name: ${this.visualName || 'my-runbook'}`];
    if (this.visualTargets.trim()) lines.push(`targets: ${this.visualTargets.trim()}`);
    lines.push('steps:');
    for (const st of steps) {
      lines.push('  -');
      if (st.name) lines.push(`    name: ${st.name}`);
      lines.push(`    module: ${st.module}`);
      if (st.when) lines.push(`    when: ${st.when}`);
      const loop = String(st.loop ?? '').trim();
      if (loop) {
        if (loop.startsWith('[')) {
          try {
            const items = JSON.parse(loop) as unknown[];
            lines.push('    loop:');
            for (const it of items) lines.push(`      - ${it}`);
          } catch { lines.push(`    loop: ${loop}`); }
        } else {
          lines.push(`    loop: ${loop}`);
        }
      }
      if (st.register) lines.push(`    register: ${st.register}`);
      if (st.ignore_errors) lines.push('    ignore_errors: true');
      const argBlock = ntBlock(st.args ?? {}, 6);
      if (argBlock) { lines.push('    args:'); lines.push(argBlock); }
    }
    return lines.join('\n') + '\n';
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
      // Lint right away: shows validity, fills the parameter mask, and keeps
      // the visual canvas in sync when it's the active view.
      this.doLint(this.mode() === 'visual');
    });
  }

  newRunbook(): void {
    this.currentId.set('');
    this.saveMsg.set('');
    this.moveFolder = '';
    this.ed?.setValue(STARTER);
    this.lint.set(null);
    if (this.mode() === 'visual') this.doLint(true);
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

  doLint(rebuildVisual = false): void {
    this.http.post<LintResult>(`${this.base}/runbooks/lint`, { nt: this.source() }).subscribe({
      next: (r) => {
        this.lint.set(r);
        this.setMarkers(r);
        if (rebuildVisual && r.ok && r.doc && r.doc.kind !== 'role') this.visualFromDoc(r.doc);
      },
      error: (e) => { const l = { ok: false, error: e?.error?.detail ?? 'lint failed' }; this.lint.set(l); this.setMarkers(l); },
    });
  }

  run(dryRun: boolean): void {
    this.running.set(true);
    this.result.set(null);
    this.http.post<RunResult>(`${this.base}/agents/${this.hostId()}/runbook/run`,
      { nt: this.source(), variables: this.runVars, dry_run: dryRun }).subscribe({
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
