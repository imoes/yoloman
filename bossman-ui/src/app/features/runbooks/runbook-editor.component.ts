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
import yaml from 'js-yaml';
// Blockly runbook designer — ported 1:1 from ../ansible-manager (plain JS).
import { registerBlocks } from './blockly/blocks';
import { buildToolbox } from './blockly/toolbox';
import { serializeWorkspace } from './blockly/ansibleGenerator';
import { CdkDropListGroup } from '@angular/cdk/drag-drop';
import { SequenceTreeComponent } from './sequence/sequence-tree.component';
import { VariablesPanelComponent } from './sequence/variables-panel.component';
import { BUILTIN_VARIABLES } from './blockly/ansibleFacts';
import { SEARCH_SCOPES, SeqNode, SearchScope, TreeFilters, filterTree, findNode, nextId,
         removeNode, searchTree, tasksToTree, treeToTasks } from './sequence/sequence-model';
import { jsonSchemaToParamSchema, optionsToParamSchema } from './sequence/module-schema';
import { importTasksYaml } from './blockly/playbookImporter';

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

const STARTER = `name: web baseline
targets: group:web-servers
tasks:
  - name: install nginx
    apt:
      name: nginx
      state: present
  - name: reload if changed
    service:
      name: nginx
      state: reloaded
    when: dropped_config.changed
`;

// The sidebar reference list comes from blockly/ansibleFacts — ONE source shared with the Variables panel.
// It used to be a second hardcoded array here, and it had drifted twice over: it advertised only the
// `yoloman_*` spelling (not `ansible_facts['x']`, which is what imported roles use), and it invented
// inventory paths (`inventory.system.serial_number`, `inventory.memory_mb`) that runbook_exec never binds.
// Two lists of the same thing is how both happened.
const MAGIC_VAR_GROUPS = (() => {
  const groups = [];
  for (const v of BUILTIN_VARIABLES) {
    const last = groups[groups.length - 1];
    if (last && last.source === v.source) last.vars.push(v);
    else groups.push({ source: v.source, vars: [v] });
  }
  // The flat `ansible_<name>` aliases exist for imported content but would triple the list for no gain here.
  return groups.filter((g) => g.source !== 'ansible fact (flat alias)');
})();

/**
 * Block G11 — the Workflow designer. Two synced views of one runbook:
 * Monaco (Ansible-task playbook YAML, server-side lint markers) and a Blockly
 * canvas (see blockly/). The round-trip is real: text→visual parses via
 * /runbooks/lint (which returns the canonical doc) and builds the blocks;
 * visual→text walks the blocks back to Ansible-task YAML. A step block renders one
 * typed field per module option (from the argspec), and `when:` is built from
 * condition blocks. A runbook's typed `parameters` render as an input mask
 * before dry-run/apply.
 */
@Component({
  selector: 'app-runbook-editor',
  standalone: true,
  imports: [DatePipe, FormsModule, MatButtonModule, MatIconModule, MatFormFieldModule, MatInputModule, MatSelectModule, ParamFormComponent, BlocklyWorkspaceComponent, SequenceTreeComponent, VariablesPanelComponent, CdkDropListGroup],
  template: `
    <div class="bm-page">
      <div class="bm-header-row">
        <h1>Workflow designer</h1>
        <span class="bm-subtitle">Author a runbook — drag modules on the canvas or edit the Ansible playbook — lint it, dry-run against a host, then apply.</span>
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
              <button mat-button [class.bm-mode-on]="mode() === 'tree'" (click)="setMode('tree')">
                <mat-icon>list</mat-icon> Sequence
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
              <span class="bm-dim">Build the runbook from blocks — pick a step from the toolbox, fill its fields; the playbook YAML stays in sync. Switch to Text any time.</span>
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
          <!-- Sequence view (slice 3): the SAME document as a tree of groups + steps, drag & drop to
               reorder. One cdkDropListGroup wraps the whole tree so a step can move between groups. -->
          @if (mode() === 'tree') {
            <!-- Toolbar + scoped search + filters, after SCCM's task-sequence editor. All three are pure
                 projections of the document: nothing here can change what runs. -->
            <div class="bm-seq-bar">
              <button mat-stroked-button (click)="addGroup()"><mat-icon>create_new_folder</mat-icon> Group</button>
              <button mat-stroked-button (click)="addStep()"><mat-icon>add</mat-icon> Step</button>
              <button mat-icon-button (click)="moveSel(-1)" [disabled]="!seqSelected()"
                      title="Move up"><mat-icon>arrow_upward</mat-icon></button>
              <button mat-icon-button (click)="moveSel(1)" [disabled]="!seqSelected()"
                      title="Move down"><mat-icon>arrow_downward</mat-icon></button>
              <button mat-icon-button (click)="removeSeqNode(seqSelected()!)" [disabled]="!seqSelected()"
                      title="Remove"><mat-icon>delete_outline</mat-icon></button>
              <span class="bm-spacer"></span>
              <input class="bm-seq-search" type="search" [ngModel]="seqQuery()"
                     (ngModelChange)="seqQuery.set($event)" placeholder="Search the sequence…" />
              <button mat-icon-button (click)="seqSearchOpen.set(!seqSearchOpen())"
                      [title]="seqSearchOpen() ? 'Hide search options' : 'Search within / filter by'">
                <mat-icon>tune</mat-icon>
              </button>
              @if (seqQuery().trim()) {
                <span class="bm-dim">{{ seqMatches().size }} match(es)</span>
              }
            </div>
            @if (seqSearchOpen()) {
              <div class="bm-seq-scopes">
                <div>
                  <div class="bm-vg">Search within</div>
                  @for (s of searchScopes; track s.key) {
                    <label class="bm-seq-chk">
                      <input type="checkbox" [checked]="seqScopes().includes(s.key)"
                             (change)="toggleScope(s.key)" /> {{ s.label }}
                    </label>
                  }
                </div>
                <div>
                  <div class="bm-vg">Filter by</div>
                  <label class="bm-seq-chk" title="Steps that record a failure and carry on (ignore_errors)">
                    <input type="checkbox" [checked]="seqFilters().continueOnError"
                           (change)="toggleFilter('continueOnError')" /> Continue on error
                  </label>
                  <label class="bm-seq-chk" title="Steps with a when: / failed_when: / changed_when:">
                    <input type="checkbox" [checked]="seqFilters().hasConditions"
                           (change)="toggleFilter('hasConditions')" /> Has conditions
                  </label>
                  <p class="bm-dim">A group stays visible when anything inside it matches — dropping it would
                    misrepresent the order its steps run in.</p>
                </div>
              </div>
            }
            <p class="bm-dim">Groups become Ansible <code>block:</code>, steps become module tasks — the
              playbook YAML stays in sync, so Text and Visual show the same document.</p>
            <!-- Tree LEFT, inspector RIGHT, variables far right — docs/design-philosophy.md #4
                 (source list → content → inspector). The form used to sit BELOW the tree as six
                 outline mat-form-fields, which is the Material default the philosophy warns about:
                 ~56px of chrome per field for a one-word value. -->
            <div class="bm-seq-layout">
              <div class="bm-seq-wrap" cdkDropListGroup>
                <app-sequence-tree [nodes]="seqNodes()" [selectedId]="seqSelected()"
                                   [matchIds]="seqMatches()" [visibleIds]="seqVisible()"
                                   (select)="selectSeqNode($event)" (remove)="removeSeqNode($event)"
                                   (changed)="syncSequence()" />
                @if (!seqNodes().length) {
                  <p class="bm-dim">No tasks yet — add a Group or a Step.</p>
                }
              </div>

              <div class="bm-seq-insp">
                @if (selectedSeqNode(); as sel) {
                  <label class="bm-f">
                    <span>Name</span>
                    <input type="text" [ngModel]="sel.name" (ngModelChange)="editSeq(sel, 'name', $event)"
                           (focus)="focusField('name')" placeholder="what this step does" />
                  </label>
                  @if (sel.kind === 'step') {
                    <label class="bm-f">
                      <span>Module</span>
                      <input type="text" [ngModel]="sel.module" (ngModelChange)="editSeq(sel, 'module', $event)"
                             list="bm-seq-modules" placeholder="community.general.lvg" />
                    </label>
                  }
                  <label class="bm-f">
                    <span>when</span>
                    <input type="text" [ngModel]="sel.when || ''" (ngModelChange)="editSeq(sel, 'when', $event)"
                           (focus)="focusField('when')" placeholder="ansible_facts['os_family'] == 'Debian'" />
                  </label>

                  <!-- Progressive disclosure (philosophy #10): the common path is Name + Module + when;
                       everything with a safe default hides until asked for. -->
                  <button type="button" class="bm-seq-adv" (click)="seqAdvanced.set(!seqAdvanced())">
                    <mat-icon>{{ seqAdvanced() ? 'expand_more' : 'chevron_right' }}</mat-icon> Advanced
                  </button>
                  @if (seqAdvanced()) {
                    <label class="bm-f">
                      <span>loop</span>
                      <input type="text" [ngModel]="loopText(sel)" (ngModelChange)="editLoop(sel, $event)"
                             (focus)="focusField('loop')" placeholder="{{ '{{ volume_groups }}' }}" />
                    </label>
                    @if (sel.kind === 'step') {
                      <label class="bm-f">
                        <span>register</span>
                        <input type="text" [ngModel]="sel.register || ''"
                               (ngModelChange)="editRegister(sel, $event)" placeholder="result" />
                      </label>
                      <label class="bm-f">
                        <span>failed_when</span>
                        <input type="text" [ngModel]="sel.extra?.['failed_when'] || ''"
                               (ngModelChange)="editExtra(sel, 'failed_when', $event)"
                               (focus)="focusField('failed_when')" placeholder="rc != 0" />
                      </label>
                      <label class="bm-seq-chk" title="Record a failure here but keep going">
                        <input type="checkbox" [checked]="!!sel.extra?.['ignore_errors']"
                               (change)="toggleIgnoreErrors(sel, $event)" /> ignore_errors
                      </label>
                    }
                  }
                  @if (sel.kind === 'group') {
                    <div class="bm-seq-branches">
                      <button mat-stroked-button (click)="addBranchStep(sel, 'rescue')"
                              title="Steps that run only if this group failed (catch)">
                        <mat-icon>replay</mat-icon> rescue step
                      </button>
                      <button mat-stroked-button (click)="addBranchStep(sel, 'always')"
                              title="Steps that run whichever way the group went (finally)">
                        <mat-icon>vertical_align_bottom</mat-icon> always step
                      </button>
                    </div>
                  }
                  <!-- The step's arguments as a TYPED form, generated from the module's argspec (its
                       schema()) — choices become dropdowns. A module the catalog does not know keeps the raw
                       JSON editor so it stays editable. -->
                  @if (sel.kind === 'step') {
                    <div class="bm-seq-args-box">
                      @if (stepSchema(); as sch) {
                        <app-param-form [params]="sch" [initial]="sel.args || {}"
                                        (valuesChange)="setStepArgs(sel, $event)" />
                      } @else {
                        <label class="bm-f">
                          <span>Arguments (JSON — this module has no argspec)</span>
                          <textarea rows="3" [ngModel]="argsText(sel)"
                                    (ngModelChange)="editArgs(sel, $event)"></textarea>
                        </label>
                        @if (argsError()) { <span class="bm-err">{{ argsError() }}</span> }
                        @if (schemaLoading()) { <span class="bm-dim">loading the module\'s argspec…</span> }
                      }
                    </div>
                  }
                } @else {
                  <p class="bm-dim">Select a step to edit it.</p>
                }
              </div>

              <!-- Variables. A role is not usable without them, and this panel was the piece the Blockly
                   port left behind. -->
              <div class="bm-seq-vars">
                <h4 class="bm-seq-vh">Variables</h4>
                <app-variables-panel [parameters]="docParameters()" [registers]="registerNames()"
                                     [inLoop]="selectedHasLoop()"
                                     (insert)="insertVariable($event)"
                                     (create)="createParameter($event)" />
              </div>
            </div>
            <datalist id="bm-seq-modules">
              @for (m of moduleNames(); track m) { <option [value]="m"></option> }
            </datalist>
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
        <div class="bm-right" [class.bm-right-thin]="mode() === 'tree'"
             [style.display]="mode() === 'visual' ? 'none' : 'block'">
          <!-- The Magic-variables REFERENCE is only for the text view: in tree mode the sequence layout
               carries an interactive variables panel (the same list, but clickable and scoped to the open
               document), so a second static copy here only ate the width the three tree columns need. -->
          @if (mode() !== 'tree') {
            <div class="bm-panel-title">Magic variables</div>
            <p class="bm-dim">Agent facts, available as <code ngNonBindable>{{ var }}</code> in args/when — no declaration:</p>
            @for (g of magicVarGroups; track g.source) {
              <div class="bm-vg">{{ g.source }}</div>
              <ul class="bm-vars">
                @for (v of g.vars; track v.name) {
                  <li class="bm-mono" [title]="v.preview">{{ ref(v.name) }}</li>
                }
              </ul>
            }
            <p class="bm-dim">Also any host/group/OU var, role parameters, and <code ngNonBindable>{{ item }}</code> in a loop.</p>
          }

          <div class="bm-panel-title" [style.margin-top]="mode() === 'tree' ? '0' : '16px'">Recent runs @if (hostId()) { <span class="bm-dim">· this host</span> }</div>
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
      .bm-vg { font-size: 10.5px; text-transform: uppercase; letter-spacing: .04em; opacity: .5;
        margin: 10px 0 2px; }
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
      /* Tree mode: variables live in the sequence panel, so the right rail is just Recent runs and can be
         narrow — that returns the width the tree/inspector/variables columns need to sit side by side. */
      .bm-right-thin { flex: 0 0 190px; }
      .bm-editor { height: 520px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: hidden; }
      .bm-mode { display: inline-flex; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: hidden; margin-left: auto; }
      .bm-mode button { border-radius: 0; }
      .bm-mode-on { background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent); font-weight: 600; }
      .bm-vbar { display: flex; align-items: center; gap: 12px; margin-bottom: 8px; flex-wrap: wrap; }
      .bm-canvas-row { display: block; margin-bottom: 10px; }
      /* Sequence view (slice 3) */
      .bm-seq-bar { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; flex-wrap: wrap; }
      .bm-seq-search { padding: 5px 8px; font-size: 12.5px; color: inherit; min-width: 150px;
        background: var(--mat-sys-surface); border: 1px solid var(--mat-sys-outline-variant);
        border-radius: 6px; }
      .bm-seq-scopes { display: flex; gap: 24px; flex-wrap: wrap; margin: 0 0 10px; padding: 10px;
        border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; }
      .bm-seq-scopes > div { display: flex; flex-direction: column; gap: 3px; max-width: 300px; }
      .bm-seq-wrap { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 8px;
        min-height: 140px; max-height: 420px; overflow: auto; }
      /* Tree | inspector | variables, wrapping when there is not room for three.
         This is FLEX, not grid with a viewport media query: the editor pane is only ~450px wide (library
         sidebar left, runs sidebar right), so a "minmax(0, 1fr) 300px 240px" grid gave the tree column 0px
         and hid it entirely — measured, not guessed. A viewport breakpoint cannot see that, because the
         viewport was 1280px while the container was 450px. flex-basis + wrap can never collapse a column. */
      .bm-seq-layout { display: flex; flex-wrap: wrap; gap: 12px; align-items: flex-start; }
      /* Bases chosen so tree + inspector sit side by side and variables flows onto the next row: the editor
         pane is only ~540px wide (library tree + right rail + assistant panel take the rest), so three
         220px+ columns across would need ~860px and just stack one-per-row. Tree+inspector ≈ 500px fits;
         variables wraps below at full width. */
      .bm-seq-wrap { flex: 1 1 250px; min-width: 0; }
      .bm-seq-insp { flex: 1 1 230px; min-width: 0; }   /* min-width:0 or auto min-content blocks the shrink */
      .bm-seq-vars { flex: 1 1 100%; min-width: 0; }
      .bm-seq-insp, .bm-seq-vars { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px;
        padding: 10px; display: flex; flex-direction: column; gap: 8px; box-sizing: border-box; }
      .bm-seq-vars { max-height: 420px; }
      /* Let the panel host fill the (max-height-bounded) column and shrink, so its inner list scrolls
         instead of the 60-row variable list bursting the box. min-height:0 is the part that lets a flex
         child shrink below its content. */
      .bm-seq-vars app-variables-panel { flex: 1 1 auto; min-height: 0; }
      .bm-seq-vh { margin: 0; font-size: 11px; text-transform: uppercase; letter-spacing: .04em; opacity: .55; }
      /* One compact field: a small label above a plain input. Replaces mat-form-field appearance="outline",
         whose floating label + subscript reserve ~56px per field — the Material default the design
         philosophy calls out ("chrome is minimal"; an ops tool is dense in DATA, not chrome). */
      .bm-f { display: flex; flex-direction: column; gap: 3px; font-size: 11px; }
      .bm-f > span { opacity: .6; }
      .bm-f input, .bm-f textarea, .bm-f select {
        padding: 5px 8px; font-size: 12.5px; color: inherit; background: var(--mat-sys-surface);
        border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; width: 100%;
        box-sizing: border-box; font-family: inherit;
      }
      .bm-f textarea { font-family: ui-monospace, monospace; font-size: 12px; resize: vertical; }
      .bm-seq-adv { display: inline-flex; align-items: center; gap: 3px; align-self: flex-start;
        background: none; border: 0; color: inherit; opacity: .65; cursor: pointer; font-size: 11.5px;
        padding: 2px 0; }
      .bm-seq-adv:hover { opacity: 1; }
      .bm-seq-adv mat-icon { font-size: 17px; width: 17px; height: 17px; }
      .bm-seq-branches { display: flex; gap: 8px; flex-wrap: wrap; }
      .bm-seq-args { min-width: 320px; flex: 1 1 320px; }
      .bm-err { color: var(--mat-sys-error, #c62828); font-size: 12px; align-self: center; }
      .bm-seq-chk { display: inline-flex; align-items: center; gap: 5px; font-size: 12.5px; opacity: .85;
        align-self: center; }
      .bm-designer { display: block; height: 560px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: hidden; min-width: 0; }
      .bm-designer-loading { display: flex; align-items: center; justify-content: center; }
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
  magicVarGroups = MAGIC_VAR_GROUPS;
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

  // Visual authoring mode, ROUND-TRIP: text→visual parses the current Ansible task YAML via
  // /runbooks/lint (which returns the canonical doc); visual→text serialises back into Monaco (the single
  // source lint/dry-run/apply read).
  mode = signal<'text' | 'visual' | 'tree'>('text');
  // The designer measures its workspace at init — instantiate it one tick AFTER
  // the visual layout settles, or it caches a tiny pre-layout size (steps end up
  // in a 180px strip behind the toolbox).
  visualReady = signal(false);
  visualName = 'my-runbook';
  visualTargets = '';
  // Handlers aren't authored in this task-list canvas (they'd need the play-block
  // mode), but must survive the visual round-trip — captured on import, re-emitted
  // on serialize so a runbook's `handlers:` are never silently dropped.
  private pendingHandlers: unknown = undefined;
  // Blockly visual designer — ported 1:1 from ../ansible-manager. The canvas owns
  // block editing (per-module blocks from the committed catalog); visual↔text uses
  // the reference serializeWorkspace/importTasksYaml over Ansible-task YAML.
  blocklyToolbox: Blockly.utils.toolbox.ToolboxDefinition = buildToolbox([]) as Blockly.utils.toolbox.ToolboxDefinition;
  private blocklyWs?: Blockly.WorkspaceSvg;
  private pendingText = '';   // Ansible-task YAML to import once the canvas mounts

  /** Switch views. text→visual imports the current Ansible-task YAML into blocks
   * (client-side, via the ported importer); visual→text serialises back. text→tree parses the same YAML
   * into the sequence tree; every edit there writes the YAML straight back, so all three views are views
   * of ONE document (docs/ui-workspaces.md). */
  setMode(m: 'text' | 'visual' | 'tree'): void {
    this.blocklyWs = undefined;   // canvas is recreated; wait for onBlocklyReady
    if (m === 'visual') {
      this.pendingText = this.source();
      this.mode.set('visual');
      this.visualReady.set(false);
      setTimeout(() => this.visualReady.set(true), 60);
      return;
    }
    if (m === 'tree') {
      this.loadSequenceFromText();
      this.mode.set('tree');
      return;
    }
    this.mode.set(m);
    // Monaco mis-measures while display:none; relayout once it's visible again.
    setTimeout(() => this.ed?.layout(), 0);
  }

  // ---- Sequence view (slice 3) -------------------------------------------------------------------
  seqNodes = signal<SeqNode[]>([]);
  seqSelected = signal<string | null>(null);
  argsError = signal('');
  moduleNames = signal<string[]>([]);
  /** The document envelope around `tasks:` — kept so serialising back preserves name/targets/handlers. */
  private seqEnvelope: Record<string, unknown> = {};
  /** Signal mirror of the envelope, so the Variables panel recomputes when `parameters:` changes. */
  private seqEnvelopeSignal = signal<Record<string, unknown>>({});

  // ---- SCCM-style search + filter. Pure projections; no document is touched. -------------------------
  searchScopes = SEARCH_SCOPES;
  seqQuery = signal('');
  seqSearchOpen = signal(false);
  /** Default scopes: what an operator most often looks for. All of them are reachable via the panel. */
  seqScopes = signal<SearchScope[]>(['stepName', 'stepType', 'groupName']);
  seqFilters = signal<TreeFilters>({});

  seqMatches = computed(() => searchTree(this.seqNodes(), this.seqQuery(), this.seqScopes()));
  seqVisible = computed(() => filterTree(this.seqNodes(), this.seqFilters()));

  toggleScope(key: SearchScope): void {
    const cur = this.seqScopes();
    this.seqScopes.set(cur.includes(key) ? cur.filter((k) => k !== key) : [...cur, key]);
  }
  toggleFilter(key: keyof TreeFilters): void {
    this.seqFilters.set({ ...this.seqFilters(), [key]: !this.seqFilters()[key] });
  }

  /**
   * Move the selected node within its own sibling list. Keyboard/button reordering next to drag & drop: a
   * long sequence is painful to drag, and SCCM offers exactly these two buttons. Staying inside the sibling
   * list is deliberate — moving across groups changes which `block:` a step belongs to, i.e. which shared
   * `when:` and error handling apply to it, so that stays an explicit drag.
   */
  moveSel(delta: number): void {
    const id = this.seqSelected();
    if (!id) return;
    const findList = (list: SeqNode[]): SeqNode[] | null => {
      if (list.some((n) => n.id === id)) return list;
      for (const n of list) {
        for (const branch of [n.children, n.rescue, n.always]) {
          const hit = branch && findList(branch);
          if (hit) return hit;
        }
      }
      return null;
    };
    const list = findList(this.seqNodes());
    if (!list) return;
    const from = list.findIndex((n) => n.id === id);
    const to = from + delta;
    if (to < 0 || to >= list.length) return;
    [list[from], list[to]] = [list[to], list[from]];
    this.syncSequence();
  }

  /** Whether the inspector's Advanced block is open (loop/register/failed_when/ignore_errors). */
  seqAdvanced = signal(false);
  /** Which inspector field last had focus, so a clicked variable lands in the right place. */
  private lastField = signal<'name' | 'when' | 'loop' | 'failed_when' | null>(null);
  focusField(f: 'name' | 'when' | 'loop' | 'failed_when'): void { this.lastField.set(f); }

  /** The document's own `parameters:` — a role's inputs. */
  docParameters = computed<Record<string, unknown>>(() => {
    const p = this.seqEnvelopeSignal()['parameters'];
    return p && typeof p === 'object' ? (p as Record<string, unknown>) : {};
  });

  /** Every `register:` name in the document, so the panel can offer them. */
  registerNames = computed<string[]>(() => {
    const out: string[] = [];
    const walk = (nodes: SeqNode[]): void => {
      for (const n of nodes) {
        if (n.register) out.push(n.register);
        walk(n.children ?? []);
        walk(n.rescue ?? []);
        walk(n.always ?? []);
      }
    };
    walk(this.seqNodes());
    return [...new Set(out)];
  });

  /** `item` is only bound inside a loop, so the panel only offers it there. */
  selectedHasLoop = computed(() => this.selectedSeqNode()?.loop !== undefined);

  /**
   * Insert `{{ name }}` into the field the operator last touched. Clicking a variable has to put it
   * SOMEWHERE, and the last-focused field is the only honest guess; when nothing was focused we fall back to
   * `when:`, which is what conditions are written in and the reason SCCM makes variables searchable at all.
   */
  insertVariable(name: string): void {
    const sel = this.selectedSeqNode();
    if (!sel) return;
    const ref = `{{ ${name} }}`;
    const field = this.lastField() ?? 'when';
    if (field === 'name') this.editSeq(sel, 'name', `${sel.name ?? ''}${ref}`);
    else if (field === 'loop') this.editLoop(sel, ref);
    else if (field === 'failed_when') this.editExtra(sel, 'failed_when', `${sel.extra?.['failed_when'] ?? ''}${ref}`);
    else this.editSeq(sel, 'when', `${sel.when ?? ''}${ref}`);
  }

  /** Add a parameter to the document itself, so a role can declare its own inputs from here. */
  createParameter(v: { name: string; value: string }): void {
    const params = { ...this.docParameters() };
    // A bare default rather than a typed spec: the operator typed a value, not a schema, and nt_runbook's
    // _parse_parameters passes a non-spec value through unchanged (the legacy free-form Role shape).
    params[v.name] = v.value;
    this.seqEnvelope = { ...this.seqEnvelope, parameters: params };
    this.seqEnvelopeSignal.set(this.seqEnvelope);
    this.syncSequence();
  }

  selectedSeqNode = computed(() => {
    const id = this.seqSelected();
    return id ? findNode(this.seqNodes(), id) : null;
  });

  /** text → tree. */
  private loadSequenceFromText(): void {
    let doc: Record<string, unknown> = {};
    try { doc = (yaml.load(this.source()) ?? {}) as Record<string, unknown>; } catch { doc = {}; }
    const tasks = Array.isArray(doc) ? doc : doc['tasks'];
    this.seqEnvelope = Array.isArray(doc) ? {} : { ...doc };
    this.seqEnvelopeSignal.set(this.seqEnvelope);
    this.seqNodes.set(tasksToTree(tasks));
    this.seqSelected.set(null);
    this.argsError.set('');
  }

  /** tree → text. The single write path for every sequence edit. */
  syncSequence(): void {
    const tasks = treeToTasks(this.seqNodes());
    const doc: Record<string, unknown> = { ...this.seqEnvelope, tasks };
    this.ed?.setValue(yaml.dump(doc, { lineWidth: -1, noRefs: true }));
  }

  addGroup(): void {
    this.seqNodes.update((ns) => [...ns, { id: nextId(), kind: 'group', name: 'New group', children: [] }]);
    this.syncSequence();
  }
  addStep(): void {
    this.seqNodes.update((ns) => [...ns, this.newStep('New step')]);
    this.syncSequence();
  }

  /**
   * A new step needs a REAL module: a task without a module key is invalid Ansible, and the document would
   * be unparseable from the moment the operator adds a step until they fill the field in (Bossman's parser
   * rejects it outright). `ping` is the honest placeholder — always present, no arguments, harmless if it
   * is ever actually run.
   */
  private newStep(name: string): SeqNode {
    return { id: nextId(), kind: 'step', name, module: 'ping', args: {} };
  }
  removeSeqNode(id: string): void {
    const ns = [...this.seqNodes()];
    removeNode(ns, id);
    this.seqNodes.set(ns);
    if (this.seqSelected() === id) this.seqSelected.set(null);
    this.syncSequence();
  }
  /** Edit one scalar field of a node, then re-serialise. Empty `when` removes the key entirely. */
  editSeq(node: SeqNode, field: 'name' | 'module' | 'when', value: string): void {
    if (field === 'when') node.when = value.trim() ? value : undefined;
    else node[field] = value;
    if (field === 'module') this.loadStepSchema(value);
    this.seqNodes.set([...this.seqNodes()]);
    this.syncSequence();
  }
  /** Select a node and load its module's argspec, so the arguments render as a typed form. */
  selectSeqNode(id: string): void {
    this.seqSelected.set(id);
    const n = findNode(this.seqNodes(), id);
    this.argsError.set('');
    this.loadStepSchema(n?.kind === 'step' ? n.module : undefined);
  }

  /** module fqcn → its argspec as a form schema (null = the catalog has no argspec for it). Cached, so
   *  selecting the same module twice does not re-fetch. */
  private schemaCache = new Map<string, ParamSchema | null>();
  private stepSchemaSig = signal<ParamSchema | null>(null);
  schemaLoading = signal(false);
  /** The selected step's form schema. */
  stepSchema = computed(() => this.stepSchemaSig());

  /**
   * Load the selected step's module argspec so its arguments render as a TYPED form (choices → dropdowns)
   * instead of raw JSON. Called when the selection or the module changes; falls back to null (raw JSON) for
   * a module the catalog does not know, so an unknown module is still editable.
   */
  private moduleIndex = new Map<string, string>();
  /** module name (as written in a task) → the selected host agent's JSON Schema for it. */
  private agentSchemas = new Map<string, ParamSchema | null>();

  /**
   * Load the selected host's module registry, which is the truth about what THIS machine can run — a host
   * may carry pushed or discovered modules the catalog does not have. It therefore still wins over the
   * catalog in loadStepSchema.
   *
   * It is no longer the only source for the native builtins: the catalog now carries all 65 of them as
   * `builtin.*` sidecars generated from this same registry (bossman/scripts/generate_builtin_sidecars.py), so
   * `apt` gets a typed argument form before any host is selected. Before that, picking no host meant a raw
   * JSON box for the most common modules in any runbook.
   */
  private loadAgentSchemas(agentId: string): void {
    if (!agentId) { this.agentSchemas.clear(); return; }
    this.http.get<{ tools?: { name?: string; input_schema?: Record<string, unknown> }[] }>(
      `${environment.apiUrl}/agents/${agentId}/tools`).subscribe({
      next: (b) => {
        const m = new Map<string, ParamSchema | null>();
        for (const t of b?.tools ?? []) {
          if (t?.name) m.set(t.name, jsonSchemaToParamSchema(t.input_schema as never));
        }
        this.agentSchemas = m;
        // Re-resolve the current selection now that host schemas are known.
        const sel = this.selectedSeqNode();
        if (sel?.kind === 'step' && sel.module) this.loadStepSchema(sel.module);
      },
      error: () => this.agentSchemas.clear(),
    });
  }

  private loadStepSchema(shortOrFqcn: string | undefined): void {
    if (!shortOrFqcn) { this.stepSchemaSig.set(null); return; }
    // The host's own registry wins: it is the truth about what this machine can run, and it is the only
    // source for native + embedded modules.
    const fromAgent = this.agentSchemas.get(shortOrFqcn);
    if (fromAgent) { this.stepSchemaSig.set(fromAgent); return; }
    // Resolve a short builtin name to its fqcn; an unknown name is asked for as-is (it may be a collection
    // module the catalog lists under exactly that key).
    const module = this.moduleIndex.get(shortOrFqcn) ?? shortOrFqcn;
    if (this.schemaCache.has(module)) { this.stepSchemaSig.set(this.schemaCache.get(module)!); return; }
    this.schemaLoading.set(true);
    this.moduleService.detail(module).subscribe({
      next: (d) => {
        const sch = optionsToParamSchema(d?.metadata?.options as Record<string, ModuleOptionSpec> | undefined);
        this.schemaCache.set(module, sch);
        this.stepSchemaSig.set(sch);
        this.schemaLoading.set(false);
      },
      error: () => {
        this.schemaCache.set(module, null);   // remember the miss; don't re-ask on every click
        this.stepSchemaSig.set(null);
        this.schemaLoading.set(false);
      },
    });
  }

  /**
   * param-form emitted the step's values → store them and re-serialise the document.
   *
   * param-form prefills every field from the schema, so a naive save would write EVERY optional argument
   * into the playbook (`pvresize: false`, `pvs: []`, …). A playbook should carry what the operator actually
   * set, so drop empties and anything still equal to the schema default — the module applies its own
   * defaults anyway, and the YAML stays diff-friendly.
   */
  setStepArgs(node: SeqNode, values: Record<string, unknown>): void {
    const schema = this.stepSchema();
    const args: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(values || {})) {
      if (v === '' || v === null || v === undefined) continue;
      if (Array.isArray(v) && !v.length) continue;
      if (v && typeof v === 'object' && !Array.isArray(v) && !Object.keys(v).length) continue;
      const spec = schema?.[k];
      const def = spec?.default;
      if (def !== undefined) {
        if (JSON.stringify(def) === JSON.stringify(v)) continue;   // untouched: still the schema default
      } else if (spec?.type === 'bool' && v === false) {
        // A boolean with no declared default: param-form emits `false` for "unchecked", which is the
        // absence of an opinion, not an instruction. Writing it would put every optional flag in the
        // playbook.
        continue;
      }
      args[k] = v;
    }
    node.args = args;
    this.seqNodes.set([...this.seqNodes()]);
    this.syncSequence();
  }

  /**
   * Add a step to a group's rescue (catch) or always (finally) branch, creating the branch on demand.
   * These were only expressible in the text view before, which made the tree a lesser editor than the YAML
   * for exactly the case where a tree helps most — error handling around a risky group.
   */
  addBranchStep(group: SeqNode, branch: 'rescue' | 'always'): void {
    const list = (group[branch] ??= []);
    list.push(this.newStep(branch === 'rescue' ? 'recover' : 'cleanup'));
    this.seqNodes.set([...this.seqNodes()]);
    this.syncSequence();
  }

  /**
   * Task keywords the model keeps in `extra` (they round-trip verbatim). failed_when decides what counts as
   * a failure — the keyword that makes `rescue` usable for a module like `command`, which reports a non-zero
   * exit as data rather than as an error.
   */
  editExtra(node: SeqNode, key: string, value: string): void {
    const extra = { ...(node.extra ?? {}) };
    if (value.trim()) extra[key] = value; else delete extra[key];
    node.extra = Object.keys(extra).length ? extra : undefined;
    this.seqNodes.set([...this.seqNodes()]);
    this.syncSequence();
  }

  /** A loop is either a Jinja expression over a list, or a literal list — show whichever it is. */
  loopText(node: SeqNode): string {
    const l = node.loop;
    if (l === undefined || l === null) return '';
    return typeof l === 'string' ? l : JSON.stringify(l);
  }

  /**
   * Edit the loop. A `[…]` value is taken as a literal list (so a short inline list stays a list in the
   * YAML), anything else is kept as the expression the operator typed — `{{ volume_groups }}` is the form
   * the restore playbooks use, and the runner resolves it through the same Jinja engine as the args.
   */
  editLoop(node: SeqNode, value: string): void {
    const text = value.trim();
    if (!text) {
      node.loop = undefined;
    } else if (text.startsWith('[')) {
      try {
        node.loop = JSON.parse(text);
      } catch {
        node.loop = text;   // not valid JSON yet — keep the text so typing isn't fought
      }
    } else {
      node.loop = text;
    }
    this.seqNodes.set([...this.seqNodes()]);
    this.syncSequence();
  }

  /** `register` names this step's result so later steps (and `when:`) can read it. */
  editRegister(node: SeqNode, value: string): void {
    node.register = value.trim() || undefined;
    this.seqNodes.set([...this.seqNodes()]);
    this.syncSequence();
  }

  toggleIgnoreErrors(node: SeqNode, ev: Event): void {
    const on = (ev.target as HTMLInputElement).checked;
    const extra = { ...(node.extra ?? {}) };
    if (on) extra['ignore_errors'] = true; else delete extra['ignore_errors'];
    node.extra = Object.keys(extra).length ? extra : undefined;
    this.seqNodes.set([...this.seqNodes()]);
    this.syncSequence();
  }

  argsText(node: SeqNode): string {
    const a = node.args ?? {};
    return Object.keys(a).length ? JSON.stringify(a, null, 1) : '{}';
  }
  /** Args are edited as JSON; invalid JSON is reported and NOT written, so a typo cannot corrupt the doc. */
  editArgs(node: SeqNode, text: string): void {
    try {
      const parsed = JSON.parse(text || '{}');
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('expected an object');
      node.args = parsed as Record<string, unknown>;
      this.argsError.set('');
      this.seqNodes.set([...this.seqNodes()]);
      this.syncSequence();
    } catch (e) {
      this.argsError.set('invalid JSON — not applied: ' + (e as Error).message);
    }
  }

  /** Serialize the Blockly workspace back into the Ansible-task YAML envelope
   * ({name, targets, tasks:[...]}) and write it into Monaco — the single source
   * lint/dry-run/apply/save read. */
  syncVisual(): void {
    if (!this.blocklyWs) return;
    let tasks: unknown = [];
    try { tasks = yaml.load(serializeWorkspace(this.blocklyWs, 'tasks')) ?? []; } catch { tasks = []; }
    const doc: Record<string, unknown> = {};
    if (this.visualName) doc['name'] = this.visualName;
    if (this.visualTargets.trim()) doc['targets'] = this.visualTargets.trim();
    doc['tasks'] = tasks;
    if (Array.isArray(this.pendingHandlers) && this.pendingHandlers.length) doc['handlers'] = this.pendingHandlers;
    this.ed?.setValue(yaml.dump(doc, { lineWidth: -1, noRefs: true }));
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
    registerBlocks();   // define the ported Blockly blocks (modules/conditions/data/…) once
    this.agentService.list().subscribe((a) => this.hosts.set(a));
    this.reloadList();
    this.loadRuns();
    // The Sequence view's step palette IS the module registry (docs/resource-protocol.md: the Library is
    // the Resource type registry) — so a newly translated module shows up in the editor with no UI change.
    this.moduleService.catalog().subscribe({
      next: (c) => {
        const mods = c.modules || [];
        this.moduleNames.set(mods.map((m) => m.fqcn).sort());
        // A playbook writes builtins by SHORT name (`apt`, `service`) while the catalog keys by fqcn
        // (`ansible.builtin.apt`), so index both — otherwise the step form falls back to raw JSON for
        // every builtin, which is most of them.
        const idx = new Map<string, string>();
        const nativeShort = new Set<string>();
        for (const m of mods) {
          // checkmk.* entries are CHECKS, not modules (the Modules page hides them too) — indexing them
          // would resolve a step's `apt` to `checkmk.apt`, i.e. the wrong thing entirely.
          if (m.fqcn.startsWith('checkmk.')) continue;
          idx.set(m.fqcn, m.fqcn);
          if (!m.name) continue;
          // A NATIVE module wins the short name, even against an already-indexed translated one. Three names
          // exist twice — dnf, yum, timezone — and at run time the agent's native Go module is what executes
          // them: internal/modules.Registry.Register REFUSES a duplicate, and the natives are registered
          // before the Starlark ones. Showing the translated module's argspec would put a form on screen
          // whose fields the running module does not accept.
          if (m.native) {
            idx.set(m.name, m.fqcn);
            nativeShort.add(m.name);
          } else if (!idx.has(m.name) && !nativeShort.has(m.name)) {
            idx.set(m.name, m.fqcn);
          }
        }
        this.moduleIndex = idx;
        // The selected step may have been waiting on this index.
        const sel = this.selectedSeqNode();
        if (sel?.kind === 'step' && sel.module && !this.stepSchemaSig()) this.loadStepSchema(sel.module);
      },
      error: () => this.moduleNames.set([]),
    });
  }

  // ---- Blockly visual designer wiring ----
  onBlocklyReady(ws: Blockly.WorkspaceSvg): void {
    this.blocklyWs = ws;
    this.importFromText();
  }
  onBlocklyChange(): void {
    this.syncVisual();
  }
  /** Import the current Ansible-task YAML into the workspace (text→visual). Events
   * off so the import doesn't echo back as an edit. Splits the {name,targets,tasks}
   * envelope — importTasksYaml wants the bare task list. */
  private importFromText(): void {
    if (!this.blocklyWs) return;
    let parsed: unknown = null;
    try { parsed = yaml.load(this.pendingText || ''); } catch { parsed = null; }
    let tasks: unknown = parsed;
    if (parsed && !Array.isArray(parsed) && typeof parsed === 'object') {
      const env = parsed as Record<string, unknown>;
      this.visualName = (env['name'] as string) ?? this.visualName;
      this.visualTargets = (env['targets'] as string) ?? (env['hosts'] as string) ?? '';
      tasks = env['tasks'] ?? [];
      this.pendingHandlers = env['handlers'];   // preserve across the round-trip
    } else {
      this.pendingHandlers = undefined;
    }
    const tasksYaml = yaml.dump(Array.isArray(tasks) ? tasks : []);
    Blockly.Events.disable();
    try {
      this.blocklyWs.clear();
      importTasksYaml(tasksYaml, this.blocklyWs);
    } finally {
      Blockly.Events.enable();
    }
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
    // The host decides which modules exist and what their schemas are, so its registry is also the step
    // form's primary schema source (native + embedded modules live only there).
    this.loadAgentSchemas(id);
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
    if (!id) { this.ed?.setValue(STARTER); this.moveFolder = ''; this.refreshVisual(); return; }
    this.http.get<{ playbook: string; folder: string }>(`${this.base}/runbooks/${id}`).subscribe((r) => {
      this.ed?.setValue(r.playbook || '');
      this.moveFolder = r.folder || '';
      this.doLint();   // validity + markers (+ parameter mask if any)
      this.refreshVisual();   // if the canvas is showing, rebuild it from the loaded YAML
    });
  }

  newRunbook(): void {
    this.currentId.set('');
    this.saveMsg.set('');
    this.moveFolder = '';
    this.ed?.setValue(STARTER);
    this.lint.set(null);
    this.refreshVisual();
  }

  /** Rebuild the Blockly canvas from the current editor text — used after
   * loading a different runbook while the Visual view is active (otherwise the
   * canvas keeps showing the previously-loaded runbook). No-op in text mode. */
  private refreshVisual(): void {
    if (this.mode() !== 'visual' || !this.blocklyWs) return;
    this.pendingText = this.source();
    this.importFromText();
  }

  save(): void {
    const playbook = this.source();
    const id = this.currentId();
    const folder = this.moveFolder.trim().replace(/^\/+|\/+$/g, '');
    const req = id
      ? this.http.put<{ id: string; name: string; folder: string }>(`${this.base}/runbooks/${id}`, { playbook, folder })
      : this.http.post<{ id: string; name: string; folder: string }>(`${this.base}/runbooks`, { playbook, folder });
    req.subscribe({
      next: (r) => { this.currentId.set(r.id); this.saveMsg.set('saved: ' + r.name); this.reloadList(); },
      error: (e) => this.saveMsg.set('save failed: ' + (e?.error?.detail ?? 'error')),
    });
  }

  ngAfterViewInit(): void {
    const dark = matchMedia('(prefers-color-scheme: dark)').matches;
    this.ed = monaco.editor.create(this.editorEl.nativeElement, {
      value: STARTER,
      language: 'yaml', // Ansible task syntax IS YAML; validation is server-side
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
    this.http.post<LintResult>(`${this.base}/runbooks/lint`, { playbook: this.source() }).subscribe({
      next: (r) => { this.lint.set(r); this.setMarkers(r); },
      error: (e) => { const l = { ok: false, error: e?.error?.detail ?? 'lint failed' }; this.lint.set(l); this.setMarkers(l); },
    });
  }

  run(dryRun: boolean): void {
    this.running.set(true);
    this.result.set(null);
    this.http.post<RunResult>(`${this.base}/agents/${this.hostId()}/runbook/run`,
      { playbook: this.source(), variables: this.runVars, dry_run: dryRun }).subscribe({
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
    return '{{ ' + v + ' }}';
  }
}
