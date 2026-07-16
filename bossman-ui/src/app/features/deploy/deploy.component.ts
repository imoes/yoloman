import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService } from '../../core/services/agent.service';
import { HostGroupService } from '../../core/services/host-group.service';
import { PlanService, StoredPlan } from '../../core/services/plan.service';
import { DeploymentRun, DeploymentService } from '../../core/services/deployment.service';
import { Agent } from '../../core/models/agent.model';
import { HostGroup } from '../../core/models/host-group.model';

interface TreeRow { kind: 'folder' | 'plan'; label: string; depth: number; path?: string; plan?: StoredPlan; }
interface ParamField { key: string; type: string; required: boolean; default: unknown; value: string; }
/** One plan queued in the Run, with its role-extracted parameter form and,
 * after execution, its per-host result. */
interface RunItem {
  prefix: string;
  name: string;
  params: ParamField[];
  loadingParams: boolean;
  showAdvanced?: boolean;
  result?: DeploymentRun;
  error?: string;
}

/**
 * The Deploy page, rebuilt (block cleanup): a plan-library folder TREE on the
 * left, a Run list on the right you drag plans into — several plans can target
 * the same host/group in one action. Each queued plan pulls its parameters out
 * of the role (the plan's `params` schema) and renders them as a pre-filled
 * form, so you fill values instead of guessing keys. Targets (hosts/groups)
 * are picked once and shared; dry-run/apply fans every queued plan out
 * server-side (one DeploymentRun each).
 */
@Component({
  selector: 'app-deploy',
  standalone: true,
  imports: [FormsModule, MatCardModule, MatButtonModule, MatIconModule, MatCheckboxModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-deploy">
      <!-- Left: plan library tree (drag a plan into the Run) -->
      <aside class="bm-tree">
        <div class="bm-tree-head"><strong>Roles</strong>
          <button mat-icon-button (click)="reload()" title="Reload"><mat-icon>refresh</mat-icon></button>
        </div>
        <ul>
          @for (r of rows(); track r.kind + (r.path || '') + (r.plan?.prefix + '/' + r.plan?.name)) {
            @if (r.kind === 'folder') {
              <li class="bm-fold" [style.padding-left.px]="8 + r.depth * 14" (click)="toggle(r.path!)">
                <mat-icon>{{ expanded().has(r.path!) ? 'folder_open' : 'folder' }}</mat-icon>{{ r.label }}
              </li>
            } @else {
              <li class="bm-plan" [style.padding-left.px]="8 + r.depth * 14"
                  draggable="true" (dragstart)="onDragStart(r.plan!, $event)"
                  (dblclick)="addToRun(r.plan!)" title="Drag this role into the Run (or double-click to add)">
                <mat-icon>description</mat-icon>{{ r.label }}
                <span class="bm-badge">{{ r.plan!.prefix }}</span>
              </li>
            }
          }
          @if (!rows().length) { <li class="bm-empty">No roles yet. Import some in Roles.</li> }
        </ul>
      </aside>

      <!-- Center: the Run (drop target) + per-plan param forms -->
      <section class="bm-run" [class.bm-run-over]="dragOver()"
               (dragover)="onDragOver($event)" (dragleave)="dragOver.set(false)" (drop)="onDrop($event)">
        <h2>Run <span class="bm-dim">— {{ runItems().length }} role(s) → {{ targetCount() }} target(s)</span></h2>
        @if (!runItems().length) {
          <div class="bm-drop-hint"><mat-icon>drag_indicator</mat-icon> Drag roles here to build a run.</div>
        }
        @for (it of runItems(); track it.prefix + '/' + it.name; let i = $index) {
          <mat-card class="bm-item"
            [class.bm-ok]="it.result?.status === 'ok'" [class.bm-partial]="it.result?.status === 'partial'" [class.bm-fail]="it.result?.status === 'failed'">
            <div class="bm-item-head">
              <mat-icon>description</mat-icon>
              <span class="bm-item-name">{{ it.prefix }}/{{ it.name }}</span>
              <span class="bm-spacer"></span>
              <button mat-icon-button (click)="removeItem(i)" title="Remove"><mat-icon>close</mat-icon></button>
            </div>
            @if (it.loadingParams) {
              <p class="bm-dim bm-pad"><mat-spinner diameter="16"></mat-spinner> loading parameters…</p>
            } @else if (it.params.length) {
              <!-- Essential only: variables the operator MUST supply (required,
                   or with no default). Everything with a safe default is
                   auto-configured and tucked under Advanced. -->
              @if (essential(it).length) {
                <div class="bm-params">
                  @for (p of essential(it); track p.key) {
                    <label class="bm-param">
                      <span class="bm-param-key">{{ p.key }}@if (p.required) { <span class="bm-req">*</span> } <span class="bm-param-type">{{ p.type }}</span></span>
                      @if (p.type === 'bool') {
                        <select [ngModel]="p.value" (ngModelChange)="p.value = $event">
                          <option value="true">true</option><option value="false">false</option>
                        </select>
                      } @else {
                        <input [ngModel]="p.value" (ngModelChange)="p.value = $event"
                               [placeholder]="p.default === null || p.default === undefined ? '' : (p.default + '')" />
                      }
                    </label>
                  }
                </div>
              } @else {
                <p class="bm-dim bm-pad">Ready — no required values (defaults auto-configured).</p>
              }
              @if (advanced(it).length) {
                <button class="bm-adv-toggle" (click)="it.showAdvanced = !it.showAdvanced">
                  <mat-icon>{{ it.showAdvanced ? 'expand_more' : 'chevron_right' }}</mat-icon>
                  Advanced ({{ advanced(it).length }} auto-configured)
                </button>
                @if (it.showAdvanced) {
                  <div class="bm-params">
                    @for (p of advanced(it); track p.key) {
                      <label class="bm-param">
                        <span class="bm-param-key">{{ p.key }} <span class="bm-param-type">{{ p.type }}</span></span>
                        @if (p.type === 'bool') {
                          <select [ngModel]="p.value" (ngModelChange)="p.value = $event">
                            <option value="true">true</option><option value="false">false</option>
                          </select>
                        } @else {
                          <input [ngModel]="p.value" (ngModelChange)="p.value = $event"
                                 [placeholder]="p.default === null || p.default === undefined ? '' : (p.default + '')" />
                        }
                      </label>
                    }
                  </div>
                }
              }
            } @else {
              <p class="bm-dim bm-pad">No parameters.</p>
            }
            @if (it.error) { <p class="bm-err bm-pad">{{ it.error }}</p> }
            @if (it.result; as r) {
              <div class="bm-res">
                <span class="bm-pill" [class.bm-pill-ok]="r.status === 'ok'" [class.bm-pill-fail]="r.status === 'failed'">{{ r.dry_run ? 'dry-run' : 'applied' }} · {{ r.status }}</span>
                <span class="bm-dim">{{ r.ok_hosts }}/{{ r.total_hosts }} ok@if (r.failed_hosts) { , {{ r.failed_hosts }} failed }</span>
              </div>
            }
          </mat-card>
        }

        @if (runItems().length) {
          <div class="bm-actions">
            <button mat-raised-button color="primary" (click)="execute(true)" [disabled]="!canRun() || running()">
              @if (running()) { <mat-spinner diameter="18"></mat-spinner> } @else { <mat-icon>visibility</mat-icon> } Dry-run all
            </button>
            @if (anyDryRunOk()) {
              <button mat-raised-button color="warn" (click)="execute(false)" [disabled]="running()"><mat-icon>rocket_launch</mat-icon> Apply all</button>
            }
            @if (!targetCount()) { <span class="bm-err">pick a target →</span> }
          </div>
        }
      </section>

      <!-- Right: targets -->
      <aside class="bm-targets">
        <h3>Targets</h3>
        <strong class="bm-tlabel">Hosts</strong>
        <div class="bm-checklist">
          @for (a of agents(); track a.id) {
            <label><mat-checkbox [checked]="selectedAgents().has(a.id)" (change)="toggleAgent(a.id)"></mat-checkbox> {{ a.name }}@if (!a.address) { <span class="bm-dim"> (no addr)</span> }</label>
          }
          @if (!agents().length) { <span class="bm-dim">No hosts.</span> }
        </div>
        <strong class="bm-tlabel">Host groups</strong>
        <div class="bm-checklist">
          @for (g of groups(); track g.id) {
            <label><mat-checkbox [checked]="selectedGroups().has(g.id)" (change)="toggleGroup(g.id)"></mat-checkbox> {{ g.name }}</label>
          }
          @if (!groups().length) { <span class="bm-dim">No groups.</span> }
        </div>
      </aside>
    </div>
  `,
  styles: [`
    .bm-deploy { display: grid; grid-template-columns: 300px 1fr 260px; gap: 12px; height: calc(100vh - 90px); padding: 12px; }
    @media (max-width: 1100px) { .bm-deploy { grid-template-columns: 1fr; height: auto; } }
    .bm-dim { opacity: 0.65; font-weight: 400; }
    .bm-err { color: var(--bm-red); }
    .bm-pad { padding: 6px 12px; display: flex; align-items: center; gap: 8px; }
    .bm-tree, .bm-targets { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: auto; display: flex; flex-direction: column; }
    .bm-tree-head { display: flex; align-items: center; justify-content: space-between; padding: 6px 12px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-tree ul { list-style: none; margin: 0; padding: 4px 0; }
    .bm-tree li { display: flex; align-items: center; gap: 6px; padding: 5px 8px; cursor: pointer; font-size: 13px; }
    .bm-tree li mat-icon { font-size: 17px; width: 17px; height: 17px; opacity: 0.7; }
    .bm-fold { font-weight: 600; }
    .bm-plan { cursor: grab; }
    .bm-plan:hover { background: color-mix(in srgb, var(--mat-sys-primary) 8%, transparent); }
    .bm-badge { margin-left: auto; font-size: 10px; padding: 0 6px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); opacity: 0.7; }
    .bm-empty { opacity: 0.6; cursor: default; }
    .bm-run { border: 2px dashed transparent; border-radius: 8px; overflow: auto; padding: 4px 8px; }
    .bm-run-over { border-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 5%, transparent); }
    .bm-run h2 { margin: 8px 4px; font-size: 18px; }
    .bm-drop-hint { display: flex; align-items: center; gap: 8px; opacity: 0.5; padding: 40px; justify-content: center; border: 2px dashed var(--mat-sys-outline-variant); border-radius: 8px; }
    .bm-item { margin-bottom: 10px; }
    .bm-item-head { display: flex; align-items: center; gap: 8px; }
    .bm-item-name { font-family: monospace; font-weight: 600; }
    .bm-spacer { flex: 1; }
    .bm-params { display: grid; grid-template-columns: 1fr 1fr; gap: 8px 14px; padding: 8px 4px; }
    @media (max-width: 700px) { .bm-params { grid-template-columns: 1fr; } }
    .bm-param { display: flex; flex-direction: column; gap: 3px; font-size: 12px; }
    .bm-param-key { font-weight: 600; }
    .bm-param-type { opacity: 0.5; font-weight: 400; font-size: 11px; }
    .bm-req { color: var(--bm-red); }
    .bm-param input, .bm-param select { padding: 6px 8px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; font-size: 13px; }
    .bm-adv-toggle { display: flex; align-items: center; gap: 4px; margin: 6px 4px 2px; padding: 4px 6px; background: none; border: none; color: inherit; opacity: 0.7; cursor: pointer; font-size: 12px; }
    .bm-adv-toggle:hover { opacity: 1; }
    .bm-adv-toggle mat-icon { font-size: 18px; width: 18px; height: 18px; }
    .bm-actions { display: flex; align-items: center; gap: 12px; margin: 8px 4px 20px; }
    .bm-res { padding: 6px 4px; display: flex; gap: 10px; align-items: center; }
    .bm-pill { font-size: 11px; padding: 1px 8px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
    .bm-pill-ok { background: color-mix(in srgb, #2e7d32 25%, transparent); }
    .bm-pill-fail { background: color-mix(in srgb, var(--bm-red) 25%, transparent); }
    .bm-item.bm-ok { border-left: 4px solid #2e7d32; } .bm-item.bm-partial { border-left: 4px solid #f9a825; } .bm-item.bm-fail { border-left: 4px solid var(--bm-red); }
    .bm-targets { padding: 8px 10px; }
    .bm-targets h3 { margin: 4px 0 8px; }
    .bm-tlabel { font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; opacity: 0.6; margin-top: 10px; display: block; }
    .bm-checklist { display: flex; flex-direction: column; gap: 1px; margin-top: 4px; }
    .bm-checklist label { display: flex; align-items: center; gap: 8px; font-size: 13px; padding: 4px 6px; border-radius: 6px; }
    .bm-checklist label:hover { background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent); }
  `],
})
export class DeployComponent implements OnInit {
  private agentService = inject(AgentService);
  private groupService = inject(HostGroupService);
  private planService = inject(PlanService);
  private deployService = inject(DeploymentService);

  plans = signal<StoredPlan[]>([]);
  agents = signal<Agent[]>([]);
  groups = signal<HostGroup[]>([]);
  expanded = signal<Set<string>>(new Set(['']));
  runItems = signal<RunItem[]>([]);
  selectedAgents = signal<Set<string>>(new Set());
  selectedGroups = signal<Set<string>>(new Set());
  dragOver = signal(false);
  running = signal(false);
  private dragged: StoredPlan | null = null;

  targetCount = computed(() => this.selectedAgents().size + this.selectedGroups().size);
  canRun = computed(() => this.runItems().length > 0 && this.targetCount() > 0);
  anyDryRunOk = computed(() => this.runItems().some((it) => it.result?.dry_run && it.result.status !== 'failed'));

  /** Folder tree over the stored plans, honoring the expanded set (same shape
   * as Plan library). */
  rows = computed<TreeRow[]>(() => {
    const byFolder = new Map<string, StoredPlan[]>();
    for (const p of this.plans()) (byFolder.get(p.folder || '') ?? byFolder.set(p.folder || '', []).get(p.folder || '')!).push(p);
    const folders = new Set<string>(['']);
    for (const f of byFolder.keys()) { const segs = f ? f.split('/') : []; for (let i = 0; i <= segs.length; i++) folders.add(segs.slice(0, i).join('/')); }
    const childFolders = (parent: string) =>
      [...folders].filter((f) => f && (parent ? f.startsWith(parent + '/') : true) && f.split('/').length === (parent ? parent.split('/').length + 1 : 1)).sort();
    const out: TreeRow[] = [];
    const walk = (folder: string, depth: number) => {
      for (const cf of childFolders(folder)) { out.push({ kind: 'folder', label: cf.split('/').pop()!, depth, path: cf }); if (this.expanded().has(cf)) walk(cf, depth + 1); }
      for (const p of (byFolder.get(folder) ?? []).sort((a, b) => a.name.localeCompare(b.name))) out.push({ kind: 'plan', label: p.name, depth, plan: p });
    };
    walk('', 0);
    return out;
  });

  ngOnInit(): void {
    this.reload();
    this.agentService.list().subscribe((a) => this.agents.set(a ?? []));
    this.groupService.list().subscribe((g) => this.groups.set(g ?? []));
  }

  reload(): void { this.planService.library().subscribe((r) => this.plans.set(r.plans ?? [])); }
  toggle(path: string): void { const s = new Set(this.expanded()); s.has(path) ? s.delete(path) : s.add(path); this.expanded.set(s); }

  onDragStart(p: StoredPlan, ev: DragEvent): void { this.dragged = p; ev.dataTransfer?.setData('text/plain', p.prefix + '/' + p.name); }
  onDragOver(ev: DragEvent): void { ev.preventDefault(); this.dragOver.set(true); }
  onDrop(ev: DragEvent): void { ev.preventDefault(); this.dragOver.set(false); if (this.dragged) { this.addToRun(this.dragged); this.dragged = null; } }

  /** Add a plan to the Run and pull its parameters out of the role. */
  addToRun(p: StoredPlan): void {
    if (this.runItems().some((it) => it.prefix === p.prefix && it.name === p.name)) return;
    const item: RunItem = { prefix: p.prefix, name: p.name, params: [], loadingParams: true };
    this.runItems.update((r) => [...r, item]);
    this.planService.document(p.prefix, p.name).subscribe({
      next: (d) => this.patch(item, { params: this.extractParams(d.formats.json), loadingParams: false }),
      error: () => this.patch(item, { loadingParams: false, error: 'could not load plan parameters' }),
    });
  }

  /** Essential-only (docs/design-philosophy.md §10): only variables the
   * operator must supply — required, or with no default — are shown; anything
   * with a safe default is auto-configured and lives under Advanced. */
  essential(it: RunItem): ParamField[] {
    return it.params.filter((p) => p.required || p.default === null || p.default === undefined);
  }
  advanced(it: RunItem): ParamField[] {
    return it.params.filter((p) => !(p.required || p.default === null || p.default === undefined));
  }

  /** Extract the role's fillable variables from a plan document. Prefer the
   * declared `params` schema (file-style plans: type/required/default). For
   * imported roles that only have `chunks`, fall back to scanning for Jinja
   * `{{ var }}` references — minus Ansible facts / loop vars (ansible_*, item,
   * dotted fact access) — so you still get a form to fill. */
  private extractParams(json: string): ParamField[] {
    let body: { params?: Record<string, { type?: string; required?: boolean; default?: unknown }> } = {};
    try { body = JSON.parse(json); } catch { return []; }
    if (body.params && Object.keys(body.params).length) {
      return Object.entries(body.params).map(([key, spec]) => ({
        key, type: spec.type || 'string', required: !!spec.required,
        default: spec.default, value: spec.default === null || spec.default === undefined ? '' : String(spec.default),
      }));
    }
    const vars = new Set<string>();
    for (const m of json.matchAll(/\{\{\s*([a-zA-Z_][a-zA-Z0-9_.]*)\s*(?:\|[^}]*)?\}\}/g)) {
      const v = m[1];
      if (v === 'item' || v.startsWith('ansible_') || v.includes('.') || v === 'inventory_hostname') continue;
      vars.add(v);
    }
    return [...vars].sort().map((key) => ({ key, type: 'string', required: false, default: undefined, value: '' }));
  }

  removeItem(i: number): void { this.runItems.update((r) => r.filter((_, idx) => idx !== i)); }
  toggleAgent(id: string): void { this.selectedAgents.update((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; }); }
  toggleGroup(id: string): void { this.selectedGroups.update((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; }); }

  private patch(item: RunItem, changes: Partial<RunItem>): void {
    this.runItems.update((rows) => rows.map((it) => (it === item || (it.prefix === item.prefix && it.name === item.name) ? { ...it, ...changes } : it)));
  }
  private coerce(p: ParamField): unknown {
    const v = p.value.trim();
    if (p.type === 'bool') return v === 'true';
    if (p.type === 'number' || p.type === 'int') return /^-?\d+$/.test(v) ? parseInt(v, 10) : v;
    return v;
  }

  /** Fan every queued plan out over the shared targets — one DeploymentRun
   * each, so several plans hit the same host/group in one action. */
  execute(dryRun: boolean): void {
    if (!this.canRun()) return;
    this.running.set(true);
    const targets = { agent_ids: [...this.selectedAgents()], group_ids: [...this.selectedGroups()] };
    const items = this.runItems();
    let pending = items.length;
    for (const it of items) {
      const params: Record<string, unknown> = {};
      for (const p of it.params) { if (p.value.trim() !== '' || p.required) params[p.key] = this.coerce(p); }
      this.deployService.run({ kind: 'stored_plan', prefix: it.prefix, name: it.name, params, dry_run: dryRun, targets } as never).subscribe({
        next: (r) => { this.patch(it, { result: r, error: undefined }); if (--pending === 0) this.running.set(false); },
        error: (e) => { this.patch(it, { error: e?.error?.detail ?? 'deployment failed' }); if (--pending === 0) this.running.set(false); },
      });
    }
  }
}
