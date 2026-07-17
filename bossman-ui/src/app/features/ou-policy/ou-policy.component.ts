import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { CdkMenu, CdkMenuItem, CdkContextMenuTrigger } from '@angular/cdk/menu';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { MatDialog } from '@angular/material/dialog';
import { DialogService } from '../../shared/dialogs/dialog.service';
import { Agent } from '../../core/models/agent.model';
import { HostGroupInput } from '../../core/models/host-group.model';
import { OUNode, OUObject } from '../../core/models/ou.model';
import { CheckRule, CheckRuleInput } from '../../core/models/monitoring.model';
import { NotificationRule, NotificationRuleInput } from '../../core/models/notification.model';
import { OrchestrationPlan, OrchestrationPlanInput } from '../../core/models/orchestration.model';
import { SystemSettings } from '../../core/models/system-settings.model';
import { AgentService } from '../../core/services/agent.service';
import { HostGroupService } from '../../core/services/host-group.service';
import { MonitoringService } from '../../core/services/monitoring.service';
import { NotificationService } from '../../core/services/notification.service';
import { OrchestrationService } from '../../core/services/orchestration.service';
import { OuService } from '../../core/services/ou.service';
import { CheckService } from '../../core/services/check.service';
import { CheckAssignment } from '../../core/models/check.model';
import {
  CheckAssignDialogComponent,
  CheckAssignDialogData,
  CheckAssignResult,
} from '../../shared/components/check-assign-dialog/check-assign-dialog.component';
import {
  ScopeVarsDialogComponent,
  ScopeVarsDialogData,
} from '../../shared/components/scope-vars-dialog/scope-vars-dialog.component';
import { SystemSettingsService } from '../../core/services/system-settings.service';
import { OuNodeDialogComponent, OuNodeDialogData } from '../../shared/components/ou-node-dialog/ou-node-dialog.component';
import { HostGroupDialogComponent, HostGroupDialogData } from '../../shared/components/host-group-dialog/host-group-dialog.component';
import {
  HostGroupMembersDialogComponent,
  HostGroupMembersDialogData,
} from '../../shared/components/host-group-members-dialog/host-group-members-dialog.component';
import { ThresholdDialogComponent, ThresholdDialogData } from '../../shared/components/threshold-dialog/threshold-dialog.component';
import { ConfigPolicyDialogComponent, ConfigPolicyDialogData, ConfigPolicyResult } from '../../shared/components/config-policy-dialog/config-policy-dialog.component';
import { OuConfigEditorComponent } from './ou-config-editor.component';
import { OrchestrationPlanDialogComponent } from '../../shared/components/orchestration-plan-dialog/orchestration-plan-dialog.component';
import { PolicyGpeditDialogComponent, PolicyGpeditDialogData } from './policy-gpedit-dialog.component';
import {
  OuLinkPlanDialogComponent,
  OuLinkPlanDialogData,
  OuLinkPlanResult,
} from '../../shared/components/ou-link-plan-dialog/ou-link-plan-dialog.component';
import {
  NotificationOuDialogComponent,
  NotificationOuDialogData,
} from '../../shared/components/notification-ou-dialog/notification-ou-dialog.component';

interface TreeRow {
  kind: 'ou' | 'object';
  depth: number;
  ou?: OUNode;
  obj?: OUObject;
  ownerOuId?: string; // for object rows: the OU it belongs to
  hasChildren?: boolean;
  expanded?: boolean;
}

/** One entry in the "Policies" palette under the tree — every policy object
 * of every type, plus unlinked orchestration plans. Dragging one onto an OU
 * links/re-scopes it there (Block L3e). */
interface PaletteItem {
  kind: 'check_rule' | 'notification' | 'host_group' | 'orchestration_link' | 'plan' | 'config_policy';
  id: string;
  label: string;
  ownerOuId: string | null; // where it currently lives; null = unlinked plan
  ownerPath: string | null;
  planId?: string; // orchestration_link / plan: the underlying plan
}

/**
 * The GPO/LDAP-browser console for the Policy & Orchestration layer
 * (Block L3, see docs/policy-orchestration-architecture.md). Left: a real
 * expandable OU tree with each OU's policy objects nested beneath it.
 * Right-click a node for a GPMC-style context menu (create OUs/objects,
 * toggle Enforced / Enabled / Block Inheritance). Right: a scope/detail
 * panel for the selected node. Full GPO inheritance (enforced, block
 * inheritance) is resolved server-side (services/gpo.py); this UI drives it.
 */
@Component({
  selector: 'app-ou-policy',
  standalone: true,
  imports: [CdkMenu, CdkMenuItem, CdkContextMenuTrigger, MatIconModule, MatButtonModule, MatSlideToggleModule, OuConfigEditorComponent],
  template: `
    <div class="bm-page">
      <div class="bm-header">
        <h1>OU / Policy</h1>
        @if (yoloMode(); as y) {
          <mat-slide-toggle [checked]="y.yolo_mode" (change)="toggleYolo($event.checked)">
            YOLO-MAN {{ y.yolo_mode ? 'ON' : 'OFF' }}
          </mat-slide-toggle>
        }
        <button mat-stroked-button (click)="createOu(null)">
          <mat-icon>create_new_folder</mat-icon> New root OU
        </button>
      </div>

      <div class="bm-split">
        <!-- Left column: the tree, with the policies palette beneath it -->
        <div class="bm-left">
        <!-- Left: the tree -->
        <div
          class="bm-tree"
          [class.bm-drop-root]="dragOuId() && dropTargetId() === '__root__'"
          (dragover)="onRootDragOver($event)"
          (dragleave)="onRootDragLeave()"
          (drop)="onRootDrop($event)"
        >
          @if (rows().length) {
            @for (row of rows(); track rowKey(row)) {
              @if (row.kind === 'ou') {
                <div
                  class="bm-node bm-ou"
                  [class.bm-selected]="isSelected(row)"
                  [class.bm-drop-target]="dropTargetId() === row.ou!.id"
                  [style.paddingLeft.px]="8 + row.depth * 18"
                  draggable="true"
                  (dragstart)="onOuDragStart(row.ou!, $event)"
                  (dragend)="onDragEnd()"
                  (dragover)="onOuDragOver(row.ou!, $event)"
                  (dragleave)="onOuDragLeave(row.ou!)"
                  (drop)="onOuDrop(row.ou!, $event)"
                  (click)="select(row)"
                  (dblclick)="toggleExpand(row.ou!)"
                  [cdkContextMenuTriggerFor]="ouMenu"
                  (contextmenu)="ctx.set(row)"
                >
                  <span class="bm-twisty" (click)="toggleExpand(row.ou!); $event.stopPropagation()">
                    {{ row.hasChildren || hasObjects(row.ou!.id) ? (row.expanded ? '▾' : '▸') : '·' }}
                  </span>
                  <mat-icon class="bm-ou-icon">{{ row.ou!.block_inheritance ? 'block' : 'folder' }}</mat-icon>
                  <span class="bm-label">{{ row.ou!.name }}</span>
                  @if (row.ou!.block_inheritance) {
                    <span class="bm-badge bm-badge-block" title="Block Inheritance">blocked</span>
                  }
                </div>
              } @else {
                <div
                  class="bm-node bm-obj"
                  [class.bm-selected]="isSelected(row)"
                  [class.bm-disabled]="!row.obj!.enabled"
                  [style.paddingLeft.px]="8 + row.depth * 18"
                  (click)="select(row)"
                  draggable="true"
                  (dragstart)="onPlacedObjDragStart(row, $event)"
                  (dragend)="onDragEnd()"
                  [cdkContextMenuTriggerFor]="objMenu"
                  (contextmenu)="ctx.set(row)"
                  title="Drag onto another OU to move it there"
                >
                  <span class="bm-twisty">·</span>
                  <mat-icon class="bm-obj-icon">{{ objIcon(row.obj!.kind) }}</mat-icon>
                  <span class="bm-label">{{ row.obj!.label }}</span>
                  @if (row.obj!.enforced) {
                    <span class="bm-badge bm-badge-enforced" title="Enforced">enforced</span>
                  }
                  @if (!row.obj!.enabled) {
                    <span class="bm-badge bm-badge-off">disabled</span>
                  }
                </div>
              }
            }
          } @else {
            <p class="bm-empty">No OUs yet — right-click here or use “New root OU”.</p>
          }
        </div>

        <!-- Policies palette: every orchestration plan, draggable onto an OU
             to link it there (Windows-GPMC "link a GPO" gesture). -->
        <div class="bm-palette">
          <div class="bm-palette-head">
            <span>Policies — drag onto an OU to link</span>
            <button mat-stroked-button class="bm-palette-new" (click)="newPolicyUnlinked()" title="Author config settings for the selected OU/group (gpedit)">
              <mat-icon>add</mat-icon> New Policy
            </button>
            <button mat-button class="bm-palette-new" (click)="newCompositePolicy()" title="Create a role / threshold / notification policy object">
              <mat-icon>tune</mat-icon> Role/threshold…
            </button>
          </div>
          @for (p of allPolicies(); track p.kind + ':' + p.id) {
            <div
              class="bm-palette-item"
              draggable="true"
              (dragstart)="onPolicyDragStart(p, $event)"
              (dragend)="onDragEnd()"
            >
              <mat-icon class="bm-obj-icon">{{ paletteIcon(p.kind) }}</mat-icon>
              <span class="bm-label">{{ p.label }}</span>
              <span class="bm-palette-loc">{{ p.ownerPath ?? '(unlinked)' }}</span>
            </div>
          } @empty {
            <p class="bm-empty">No policies yet — right-click an OU to add one.</p>
          }
        </div>
        </div>

        <!-- Right: detail / scope panel -->
        <div class="bm-detail">
          @if (selected(); as sel) {
            @if (sel.kind === 'ou') {
              <h2>{{ sel.ou!.name }}</h2>
              <table class="bm-kv">
                <tr><th>Path</th><td>{{ sel.ou!.path }}</td></tr>
                <tr><th>ltree</th><td>{{ sel.ou!.ltree_path }}</td></tr>
                <tr><th>Block Inheritance</th><td>{{ sel.ou!.block_inheritance ? 'yes' : 'no' }}</td></tr>
                <tr><th>Objects</th><td>{{ (objectsByOu().get(sel.ou!.id) || []).length }}</td></tr>
              </table>
              @if (ouChecks().length) {
                <h3 class="bm-checks-h">Checks (GPO — inherited by hosts in this OU)</h3>
                <table class="bm-kv">
                  @for (c of ouChecks(); track c.id) {
                    <tr>
                      <th>{{ c.check_name }}</th>
                      <td>
                        <span class="bm-dim">{{ paramsSummary(c.parameters) }}</span>
                        <button class="bm-link" (click)="removeAssignment(c, sel.ou!.id)">remove</button>
                      </td>
                    </tr>
                  }
                </table>
              }
              <p class="bm-hint">Right-click to add OUs/objects, assign a check, toggle Block Inheritance, or delete. A host's own check config overrides these.</p>
              <app-ou-config-editor [scope]="{ kind: 'ou', id: sel.ou!.id, label: sel.ou!.path }" />
            } @else {
              <h2>{{ sel.obj!.label }}</h2>
              <table class="bm-kv">
                <tr><th>Kind</th><td>{{ sel.obj!.kind }}</td></tr>
                <tr><th>Enforced</th><td>{{ sel.obj!.enforced ? 'yes' : 'no' }}</td></tr>
                <tr><th>Enabled</th><td>{{ sel.obj!.enabled ? 'yes' : 'no' }}</td></tr>
              </table>
              <p class="bm-hint">Right-click to toggle Enforced / Enabled or delete.</p>
              <!-- A host group gets the SAME full gpedit editor as an OU,
                   scoped to the group (policies for groups, like OUs). -->
              @if (sel.obj!.kind === 'host_group') {
                <app-ou-config-editor [scope]="{ kind: 'group', id: sel.obj!.id, label: sel.obj!.label }" />
              }
            }
          } @else {
            <p class="bm-empty">Select a node to see its scope.</p>
          }
        </div>
      </div>
    </div>

    <!-- OU context menu -->
    <ng-template #ouMenu>
      <div class="bm-menu" cdkMenu>
        <button class="bm-menu-item" cdkMenuItem (click)="createOu(ctx()!.ou!.id)">New OU…</button>
        <div class="bm-menu-sep"></div>
        <!-- The multi-entry editor (several thresholds/checks/roles/routes in
             one policy) — the primary GPO-style "create a policy" action. -->
        <button class="bm-menu-item bm-menu-strong" cdkMenuItem (click)="newOrchestrationPlan(ctx()!.ou!)">
          New Policy… (multiple entries)
        </button>
        <button class="bm-menu-item" cdkMenuItem (click)="linkPlan(ctx()!.ou!)">Bind Policy (OU / Host / Group)…</button>
        <div class="bm-menu-sep"></div>
        <div class="bm-menu-label">Quick add (single entry)</div>
        <button class="bm-menu-item" cdkMenuItem (click)="newThreshold(ctx()!.ou!)">Threshold…</button>
        <button class="bm-menu-item" cdkMenuItem (click)="newConfigSetting(ctx()!.ou!)">Config setting…</button>
        <button class="bm-menu-item" cdkMenuItem (click)="newNotification(ctx()!.ou!)">Notification…</button>
        <button class="bm-menu-item" cdkMenuItem (click)="newHostGroup(ctx()!.ou!)">Host Group…</button>
        <div class="bm-menu-sep"></div>
        <button class="bm-menu-item" cdkMenuItem (click)="assignCheckToOu(ctx()!.ou!)">Assign Check…</button>
        <button class="bm-menu-item" cdkMenuItem (click)="editOuVars(ctx()!.ou!)">Variables…</button>
        <div class="bm-menu-sep"></div>
        <button class="bm-menu-item" cdkMenuItem (click)="toggleBlock(ctx()!.ou!)">
          {{ ctx()?.ou?.block_inheritance ? '✓ ' : '' }}Block Inheritance
        </button>
        <div class="bm-menu-sep"></div>
        <button class="bm-menu-item bm-danger" cdkMenuItem (click)="deleteOu(ctx()!.ou!)">Delete OU</button>
      </div>
    </ng-template>

    <!-- Object context menu -->
    <ng-template #objMenu>
      <div class="bm-menu" cdkMenu>
        @if (ctx()?.obj?.kind === 'check_rule' || ctx()?.obj?.kind === 'notification') {
          <button class="bm-menu-item" cdkMenuItem (click)="editObject(ctx()!)">Edit…</button>
          <button class="bm-menu-item" cdkMenuItem (click)="toggleEnforced(ctx()!)">
            {{ ctx()?.obj?.enforced ? '✓ ' : '' }}Enforced
          </button>
          <button class="bm-menu-item" cdkMenuItem (click)="toggleEnabled(ctx()!)">
            {{ ctx()?.obj?.enabled ? '✓ ' : '' }}Link Enabled
          </button>
          <div class="bm-menu-sep"></div>
        }
        @if (ctx()?.obj?.kind === 'check_rule') {
          <button class="bm-menu-item" cdkMenuItem (click)="unlinkFromOu(ctx()!)">Unlink from this OU</button>
          <div class="bm-menu-sep"></div>
        }
        @if (ctx()?.obj?.kind === 'host_group') {
          <button class="bm-menu-item" cdkMenuItem (click)="manageMembers(ctx()!)">Members…</button>
          <button class="bm-menu-item" cdkMenuItem (click)="assignCheckToGroup(ctx()!)">Assign Check…</button>
          <button class="bm-menu-item" cdkMenuItem (click)="newGroupConfigSetting(ctx()!)">Config setting…</button>
          <button class="bm-menu-item" cdkMenuItem (click)="editGroupVars(ctx()!)">Variables…</button>
          <div class="bm-menu-sep"></div>
        }
        <button class="bm-menu-item bm-danger" cdkMenuItem (click)="deleteObject(ctx()!)">Delete</button>
      </div>
    </ng-template>
  `,
  styles: [
    `
      .bm-page { padding: 24px; max-width: 1100px; margin: 0 auto; }
      .bm-header { display: flex; align-items: center; gap: 16px; margin-bottom: 16px; }
      .bm-header h1 { margin: 0; flex: 0 0 auto; }
      .bm-split { display: flex; gap: 16px; align-items: flex-start; }
      .bm-left { flex: 1 1 60%; display: flex; flex-direction: column; gap: 12px; min-width: 0; }
      .bm-tree {
        border: 1px solid var(--mat-sys-outline-variant);
        border-radius: 8px;
        padding: 6px 0;
        min-height: 320px;
        overflow-x: auto;
      }
      .bm-palette {
        border: 1px solid var(--mat-sys-outline-variant);
        border-radius: 8px;
        padding: 6px 0 8px;
      }
      .bm-palette-head {
        font-size: 12px; opacity: 0.7; padding: 4px 12px 6px; text-transform: uppercase; letter-spacing: 0.04em;
        display: flex; align-items: center; justify-content: space-between; gap: 8px;
      }
      .bm-palette-new { transform: scale(0.85); transform-origin: right center; }
      .bm-palette-item {
        display: flex; align-items: center; gap: 6px; padding: 5px 12px;
        cursor: grab; white-space: nowrap; user-select: none;
      }
      .bm-palette-item:active { cursor: grabbing; }
      .bm-palette-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
      .bm-palette-loc { margin-left: auto; font-size: 11px; opacity: 0.55; }
      .bm-detail {
        flex: 1 1 40%;
        border: 1px solid var(--mat-sys-outline-variant);
        border-radius: 8px;
        padding: 12px 16px;
        min-height: 320px;
      }
      .bm-node {
        display: flex; align-items: center; gap: 6px;
        padding: 4px 10px; cursor: pointer; white-space: nowrap; user-select: none;
      }
      .bm-node:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
      .bm-selected { background: color-mix(in srgb, var(--bm-green) 16%, transparent) !important; }
      .bm-ou { cursor: grab; }
      .bm-ou:active { cursor: grabbing; }
      .bm-drop-target {
        outline: 2px solid var(--bm-green);
        outline-offset: -2px;
        background: color-mix(in srgb, var(--bm-green) 12%, transparent);
      }
      .bm-drop-root { outline: 2px dashed color-mix(in srgb, var(--bm-green) 60%, transparent); outline-offset: -4px; }
      .bm-disabled .bm-label { text-decoration: line-through; opacity: 0.6; }
      .bm-twisty { width: 14px; text-align: center; opacity: 0.7; }
      .bm-ou-icon, .bm-obj-icon { font-size: 18px; height: 18px; width: 18px; }
      .bm-obj-icon { opacity: 0.7; }
      .bm-label { font-size: 13.5px; }
      .bm-badge { font-size: 10px; padding: 1px 6px; border-radius: 999px; margin-left: 4px; }
      .bm-badge-enforced { background: color-mix(in srgb, var(--bm-gold) 30%, transparent); }
      .bm-badge-block { background: color-mix(in srgb, var(--bm-red) 26%, transparent); }
      .bm-badge-off { background: color-mix(in srgb, var(--mat-sys-on-surface) 14%, transparent); }
      .bm-empty { opacity: 0.7; padding: 12px 16px; }
      .bm-hint { opacity: 0.6; font-size: 12.5px; margin-top: 16px; }
      .bm-checks-h { font-size: 12px; opacity: 0.75; margin: 16px 0 4px; }
      .bm-link { background: none; border: none; color: var(--bm-green); cursor: pointer; font: inherit; margin-left: 8px; padding: 0; }
      .bm-kv { border-collapse: collapse; margin-top: 8px; }
      .bm-kv th { text-align: left; opacity: 0.7; padding: 4px 16px 4px 0; font-weight: 500; vertical-align: top; }
      .bm-kv td { padding: 4px 0; }
      .bm-menu {
        background: var(--mat-sys-surface-container-high, #2a2a2a);
        border: 1px solid var(--mat-sys-outline-variant);
        border-radius: 6px; padding: 4px; min-width: 180px;
        box-shadow: 0 4px 16px rgba(0,0,0,0.4);
      }
      .bm-menu-item {
        display: block; width: 100%; text-align: left; background: none; border: none;
        color: inherit; padding: 7px 12px; font: inherit; cursor: pointer; border-radius: 4px;
      }
      .bm-menu-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
      .bm-menu-strong { font-weight: 600; color: var(--bm-green); }
      .bm-menu-label { font-size: 10px; text-transform: uppercase; letter-spacing: 0.05em; opacity: 0.5; padding: 4px 12px 2px; }
      .bm-danger { color: var(--bm-red); }
      .bm-menu-sep { height: 1px; background: var(--mat-sys-outline-variant); margin: 4px 0; }
    `,
  ],
})
export class OuPolicyComponent implements OnInit {
  private ouService = inject(OuService);
  private monitoring = inject(MonitoringService);
  private notification = inject(NotificationService);
  private hostGroup = inject(HostGroupService);
  private orchestration = inject(OrchestrationService);
  private agentService = inject(AgentService);
  private systemSettings = inject(SystemSettingsService);
  private checkService = inject(CheckService);
  private dialog = inject(MatDialog);
  private appDialog = inject(DialogService);

  /** GPO check assignments on the selected OU (Block G9-P3). */
  ouChecks = signal<CheckAssignment[]>([]);

  ous = signal<OUNode[]>([]);
  expanded = signal<Set<string>>(new Set());
  objectsByOu = signal<Map<string, OUObject[]>>(new Map());
  selected = signal<TreeRow | null>(null);
  ctx = signal<TreeRow | null>(null);
  yoloMode = signal<SystemSettings | null>(null);
  /** Drag-and-drop reparenting (Block L3e): the OU currently being dragged,
   * and the current drop target ('__root__' = the forest root). */
  dragOuId = signal<string | null>(null);
  dropTargetId = signal<string | null>(null);
  /** All orchestration plans (used to surface unlinked ones in the palette). */
  plans = signal<OrchestrationPlan[]>([]);
  /** The palette item currently being dragged onto an OU to link/re-scope it. */
  dragPolicy = signal<PaletteItem | null>(null);

  /** The "Policies" palette: every policy object of every type across all
   * OUs (flattened from objectsByOu), plus orchestration plans that aren't
   * linked anywhere yet — so the whole policy set is listed under the tree
   * and each entry can be dragged onto an OU to link/re-scope it. */
  allPolicies = computed<PaletteItem[]>(() => {
    const ouPath = new Map(this.ous().map((o) => [o.id, o.path] as const));
    const items: PaletteItem[] = [];
    const linkedPlanIds = new Set<string>();
    for (const [ouId, objs] of this.objectsByOu()) {
      for (const o of objs) {
        if (o.kind === 'orchestration_link' && o.plan_id) linkedPlanIds.add(o.plan_id);
        items.push({
          kind: o.kind,
          id: o.id,
          label: o.label,
          ownerOuId: ouId,
          ownerPath: ouPath.get(ouId) ?? null,
          planId: o.plan_id ?? undefined,
        });
      }
    }
    // Orchestration plans not linked to any OU yet — draggable to their first link.
    for (const p of this.plans()) {
      if (!linkedPlanIds.has(p.id)) {
        items.push({ kind: 'plan', id: p.id, label: p.display_name || p.name, ownerOuId: null, ownerPath: null, planId: p.id });
      }
    }
    items.sort((a, b) => a.kind.localeCompare(b.kind) || a.label.localeCompare(b.label));
    return items;
  });

  private childrenByParent = computed(() => {
    const map = new Map<string | null, OUNode[]>();
    for (const ou of this.ous()) {
      const key = ou.parent_id;
      const list = map.get(key) ?? [];
      list.push(ou);
      map.set(key, list);
    }
    for (const list of map.values()) list.sort((a, b) => a.name.localeCompare(b.name));
    return map;
  });

  rows = computed<TreeRow[]>(() => {
    const out: TreeRow[] = [];
    const byParent = this.childrenByParent();
    const exp = this.expanded();
    const objs = this.objectsByOu();
    const walk = (parentId: string | null, depth: number) => {
      for (const ou of byParent.get(parentId) ?? []) {
        const childOus = byParent.get(ou.id) ?? [];
        const ouObjs = objs.get(ou.id) ?? [];
        const isExpanded = exp.has(ou.id);
        out.push({
          kind: 'ou', ou, depth, hasChildren: childOus.length > 0, expanded: isExpanded,
        });
        if (isExpanded) {
          for (const obj of ouObjs) {
            out.push({ kind: 'object', obj, ownerOuId: ou.id, depth: depth + 1 });
          }
          walk(ou.id, depth + 1);
        }
      }
    };
    walk(null, 0);
    return out;
  });

  ngOnInit(): void {
    this.reload();
    this.systemSettings.getYoloMode().subscribe((s) => this.yoloMode.set(s));
  }

  private reload(): void {
    this.ouService.list().subscribe((ous) => {
      this.ous.set(ous);
      // Load every OU's objects up front so existing policies are visible on
      // a fresh page load / reload — previously objects loaded only on expand,
      // so a reload showed an empty tree until a new policy was created. OUs
      // that actually have objects auto-expand so the policies are on screen.
      const parentOf = new Map(ous.map((o) => [o.id, o.parent_id] as const));
      for (const ou of ous) {
        this.ouService.objects(ou.id).subscribe((objs) => {
          this.objectsByOu.update((m) => new Map(m).set(ou.id, objs));
          if (objs.length) {
            // Expand this OU AND all its ancestors, so a policy on a nested OU
            // is actually visible in the tree (not hidden under a collapsed
            // parent).
            this.expanded.update((e) => {
              const next = new Set(e);
              let cur: string | null | undefined = ou.id;
              while (cur) {
                next.add(cur);
                cur = parentOf.get(cur) ?? null;
              }
              return next;
            });
          }
        });
      }
    });
    this.orchestration.listPlans().subscribe((plans) => this.plans.set(plans));
  }

  private reloadObjects(ouId: string): void {
    this.ouService.objects(ouId).subscribe((objs) => {
      this.objectsByOu.update((m) => new Map(m).set(ouId, objs));
    });
  }

  rowKey(row: TreeRow): string {
    return row.kind === 'ou' ? `ou:${row.ou!.id}` : `obj:${row.ownerOuId}:${row.obj!.id}`;
  }

  isSelected(row: TreeRow): boolean {
    const sel = this.selected();
    if (!sel || sel.kind !== row.kind) return false;
    return sel.kind === 'ou' ? sel.ou!.id === row.ou!.id : sel.obj!.id === row.obj!.id;
  }

  hasObjects(ouId: string): boolean {
    return (this.objectsByOu().get(ouId) ?? []).length > 0;
  }

  objIcon(kind: OUObject['kind']): string {
    return { check_rule: 'speed', notification: 'notifications', host_group: 'dns', orchestration_link: 'widgets', config_policy: 'dataset' }[kind];
  }

  select(row: TreeRow): void {
    this.selected.set(row);
    this.ouChecks.set([]);
    if (row.kind === 'ou') this.loadOuChecks(row.ou!.id);
  }

  private loadOuChecks(ouId: string): void {
    this.checkService.listAssignments({ ou_id: ouId }).subscribe((r) => this.ouChecks.set(r.assignments));
  }

  paramsSummary(params: Record<string, unknown>): string {
    const keys = Object.keys(params || {});
    return keys.length ? keys.map((k) => k + '=' + JSON.stringify(params[k])).join(', ') : '(defaults)';
  }

  /** GPO-assign a check to this OU (inherited by every host in the OU;
   * a host's own config overrides it). */
  assignCheckToOu(ou: OUNode): void {
    const ref = this.dialog.open<CheckAssignDialogComponent, CheckAssignDialogData, CheckAssignResult>(
      CheckAssignDialogComponent, { width: '460px', data: { scopeLabel: 'OU ' + ou.path } },
    );
    ref.afterClosed().subscribe((res) => {
      if (!res) return;
      this.checkService
        .createAssignment({ check_name: res.check_name, scope_type: 'ou', ou_id: ou.id, parameters: res.parameters })
        .subscribe({
          next: () => { this.select({ kind: 'ou', ou, depth: 0 }); },
          error: (e) => this.appDialog.notify(e?.error?.detail ?? 'assign failed', 'error'),
        });
    });
  }

  assignCheckToGroup(row: TreeRow): void {
    const groupId = row.obj!.id;
    const ref = this.dialog.open<CheckAssignDialogComponent, CheckAssignDialogData, CheckAssignResult>(
      CheckAssignDialogComponent, { width: '460px', data: { scopeLabel: 'group ' + row.obj!.label } },
    );
    ref.afterClosed().subscribe((res) => {
      if (!res) return;
      this.checkService
        .createAssignment({ check_name: res.check_name, scope_type: 'group', host_group_id: groupId, parameters: res.parameters })
        .subscribe({ error: (e) => this.appDialog.notify(e?.error?.detail ?? 'assign failed', 'error') });
    });
  }

  /** GPO-style variables for a runbook run: inherited by every host in the OU,
   * overridable per group and per host (group < OU root→leaf < host). */
  editOuVars(ou: OUNode): void {
    this.dialog.open<ScopeVarsDialogComponent, ScopeVarsDialogData, boolean>(
      ScopeVarsDialogComponent, { width: '560px', data: { scopeType: 'ou', scopeId: ou.id, scopeLabel: 'OU ' + ou.path } },
    );
  }

  editGroupVars(row: TreeRow): void {
    this.dialog.open<ScopeVarsDialogComponent, ScopeVarsDialogData, boolean>(
      ScopeVarsDialogComponent, { width: '560px', data: { scopeType: 'group', scopeId: row.obj!.id, scopeLabel: 'group ' + row.obj!.label } },
    );
  }

  removeAssignment(a: CheckAssignment, ouId: string): void {
    this.checkService.deleteAssignment(a.id).subscribe({ next: () => this.loadOuChecks(ouId) });
  }

  toggleExpand(ou: OUNode): void {
    const exp = new Set(this.expanded());
    if (exp.has(ou.id)) {
      exp.delete(ou.id);
    } else {
      exp.add(ou.id);
      if (!this.objectsByOu().has(ou.id)) this.reloadObjects(ou.id);
    }
    this.expanded.set(exp);
  }

  toggleYolo(enabled: boolean): void {
    this.systemSettings.setYoloMode({ enabled }).subscribe((s) => this.yoloMode.set(s));
  }

  // --- drag-and-drop reparenting (Block L3e) ---

  /** True if `target` is inside the dragged OU's own subtree (or is it) — such
   * a drop would create a cycle and the server would reject it, so we forbid
   * it in the UI too (no drop highlight, drop ignored). Uses the materialized
   * ltree_path: a descendant's path starts with "<dragged>." (or equals it). */
  private wouldCycle(targetOu: OUNode): boolean {
    const dragged = this.ous().find((o) => o.id === this.dragOuId());
    if (!dragged) return true;
    const dp = dragged.ltree_path;
    const tp = targetOu.ltree_path;
    return tp === dp || tp.startsWith(dp + '.');
  }

  onOuDragStart(ou: OUNode, event: DragEvent): void {
    this.dragOuId.set(ou.id);
    event.dataTransfer?.setData('text/plain', ou.id);
    if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move';
  }

  paletteIcon(kind: PaletteItem['kind']): string {
    return {
      check_rule: 'speed', notification: 'notifications', host_group: 'dns',
      orchestration_link: 'widgets', plan: 'widgets', config_policy: 'dataset',
    }[kind];
  }

  /** A policy dragged from the palette (any type). */
  onPolicyDragStart(item: PaletteItem, event: DragEvent): void {
    this.dragPolicy.set(item);
    event.dataTransfer?.setData('text/plain', item.id);
    if (event.dataTransfer) event.dataTransfer.effectAllowed = 'link';
  }

  /** Drag an ALREADY-PLACED object (a policy nested under an OU) onto another
   * OU to move/re-scope it — the piece that was missing (you could place from
   * the palette but not move afterwards). Reuses the palette drop path by
   * presenting the object as a PaletteItem carrying its current owner OU. */
  onPlacedObjDragStart(row: TreeRow, event: DragEvent): void {
    const o = row.obj!;
    this.dragPolicy.set({
      kind: o.kind, id: o.id, label: o.label,
      ownerOuId: row.ownerOuId ?? null, ownerPath: null, planId: o.plan_id ?? undefined,
    });
    event.dataTransfer?.setData('text/plain', o.id);
    if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move';
    event.stopPropagation();
  }

  onDragEnd(): void {
    this.dragOuId.set(null);
    this.dragPolicy.set(null);
    this.dropTargetId.set(null);
  }

  onOuDragOver(ou: OUNode, event: DragEvent): void {
    const ouMove = !!this.dragOuId() && this.dragOuId() !== ou.id && !this.wouldCycle(ou);
    const policyLink = !!this.dragPolicy() && this.dragPolicy()!.ownerOuId !== ou.id;
    if (!ouMove && !policyLink) return;
    event.preventDefault(); // allow the drop
    event.stopPropagation(); // don't also mark the root zone
    if (event.dataTransfer) event.dataTransfer.dropEffect = policyLink ? 'link' : 'move';
    this.dropTargetId.set(ou.id);
  }

  onOuDragLeave(ou: OUNode): void {
    if (this.dropTargetId() === ou.id) this.dropTargetId.set(null);
  }

  onOuDrop(ou: OUNode, event: DragEvent): void {
    event.preventDefault();
    event.stopPropagation();
    const policy = this.dragPolicy();
    const draggedOu = this.dragOuId();
    const cyclic = draggedOu ? this.wouldCycle(ou) : false; // compute while dragOuId still set
    this.dropTargetId.set(null);
    this.dragOuId.set(null);
    this.dragPolicy.set(null);
    // A policy dropped onto an OU → link/re-scope it there (the Windows-GPMC
    // "link a GPO" gesture), dispatched by type.
    if (policy && policy.ownerOuId !== ou.id) {
      this.relinkPolicy(policy, ou.id);
      return;
    }
    // An OU dropped onto another OU → reparent.
    if (!draggedOu || draggedOu === ou.id || cyclic) return;
    this.ouService.move(draggedOu, ou.id).subscribe({
      next: () => {
        this.expanded.update((e) => new Set(e).add(ou.id));
        this.reload();
      },
      error: (e) => this.appDialog.notify(e?.error?.detail ?? 'move failed', 'error'),
    });
  }

  /** Move/link one palette policy to a target OU, per type. On success the
   * whole tree reloads so the object moves to its new OU (and the palette's
   * owner label updates). */
  private relinkPolicy(item: PaletteItem, ouId: string): void {
    const done = () => {
      this.expanded.update((e) => new Set(e).add(ouId));
      this.reload();
    };
    const fail = (e: { error?: { detail?: string } }) => this.appDialog.notify(e?.error?.detail ?? 'link failed', 'error');
    switch (item.kind) {
      case 'check_rule':
        // Multi-OU: ADD a link to this OU (one policy → many OUs) rather than
        // moving its single scope, so the same policy can govern several OUs.
        this.monitoring.addOuLink(item.id, ouId).subscribe({ next: done, error: fail });
        break;
      case 'notification':
        this.notification.patchRule(item.id, { ou_id: ouId }).subscribe({ next: done, error: fail });
        break;
      case 'host_group':
        this.hostGroup.patchOu(item.id, ouId).subscribe({ next: done, error: fail });
        break;
      case 'orchestration_link':
        // Re-scope a link by relinking its plan to the new OU, then dropping
        // the old link (delete+create — there's no link-move endpoint).
        if (!item.planId) return;
        this.orchestration.createLink(item.planId, { target_type: 'ou', ou_id: ouId, require_approval: true }).subscribe({
          next: () => this.orchestration.deleteLinkById(item.id).subscribe({ next: done, error: done }),
          error: fail,
        });
        break;
      case 'plan':
        this.orchestration
          .createLink(item.planId!, { target_type: 'ou', ou_id: ouId, require_approval: true })
          .subscribe({ next: done, error: fail });
        break;
      case 'config_policy':
        this.ouService.rescopeConfigPolicy(item.id, { scope_ou_id: ouId }).subscribe({ next: done, error: fail });
        break;
    }
  }

  onRootDragOver(event: DragEvent): void {
    if (!this.dragOuId()) return;
    event.preventDefault();
    this.dropTargetId.set('__root__');
  }

  onRootDragLeave(): void {
    if (this.dropTargetId() === '__root__') this.dropTargetId.set(null);
  }

  onRootDrop(event: DragEvent): void {
    event.preventDefault();
    const dragged = this.dragOuId();
    this.dropTargetId.set(null);
    this.dragOuId.set(null);
    if (!dragged) return;
    // Already a root OU? no-op.
    const node = this.ous().find((o) => o.id === dragged);
    if (!node || node.parent_id === null) return;
    this.ouService.move(dragged, null).subscribe({
      next: () => this.reload(),
      error: (e) => this.appDialog.notify(e?.error?.detail ?? 'move failed', 'error'),
    });
  }

  // --- OU actions ---

  createOu(parentId: string | null): void {
    const ref = this.dialog.open<OuNodeDialogComponent, OuNodeDialogData, { name: string; parent_id?: string | null }>(
      OuNodeDialogComponent,
      { width: '420px', data: { nodes: this.ous() } },
    );
    ref.afterClosed().subscribe((input) => {
      if (!input) return;
      const body = { name: input.name, parent_id: parentId ?? input.parent_id ?? null };
      this.ouService.create(body).subscribe(() => {
        if (parentId) this.expanded.update((e) => new Set(e).add(parentId));
        this.reload();
      });
    });
  }

  deleteOu(ou: OUNode): void {
    this.ouService.delete(ou.id).subscribe({ next: () => this.reload(), error: (e) => this.appDialog.notify(e?.error?.detail ?? 'delete failed', 'error') });
  }

  toggleBlock(ou: OUNode): void {
    this.ouService.setBlockInheritance(ou.id, !ou.block_inheritance).subscribe(() => this.reload());
  }

  // --- object creation ---

  newThreshold(ou: OUNode): void {
    const ref = this.dialog.open<ThresholdDialogComponent, ThresholdDialogData, CheckRuleInput>(ThresholdDialogComponent, {
      width: '460px', data: { ouId: ou.id, ouPath: ou.path },
    });
    ref.afterClosed().subscribe((input) => {
      if (!input) return;
      this.monitoring.createCheckRule(input).subscribe(() => this.afterObjectChange(ou.id));
    });
  }

  /** Block K4 — author a config-value policy at OU scope from the Policy
   * console (gpedit's "add a setting"). The dialog names a file/codec/key/
   * value; we build the {key: value} document (null = removed) and POST it,
   * which persists the policy and converges every reachable member host. */
  newConfigSetting(ou: OUNode): void {
    this.openConfigSettingDialog('OU ' + ou.path, (values, format, path) =>
      this.ouService.createConfigPolicy({ scope_ou_id: ou.id, path, format, values }),
      () => this.afterObjectChange(ou.id),
    );
  }

  newGroupConfigSetting(row: TreeRow): void {
    const groupId = row.obj!.id;
    this.openConfigSettingDialog('group ' + row.obj!.label, (values, format, path) =>
      this.ouService.createConfigPolicy({ host_group_id: groupId, path, format, values }),
      () => this.reload(),
    );
  }

  private openConfigSettingDialog(
    scopeLabel: string,
    post: (values: Record<string, unknown>, format: string, path: string) => ReturnType<OuService['createConfigPolicy']>,
    done: () => void,
  ): void {
    const ref = this.dialog.open<ConfigPolicyDialogComponent, ConfigPolicyDialogData, ConfigPolicyResult>(
      ConfigPolicyDialogComponent, { width: '480px', data: { scopeLabel } },
    );
    ref.afterClosed().subscribe((res) => {
      if (!res) return;
      const value = res.removed ? null : res.value;
      const values = this.unflattenSetting(res.key, value, res.format !== 'keyvalue');
      post(values, res.format, res.path).subscribe({
        next: (r) => {
          const msg = r.applied_hosts.length
            ? `Policy applied to ${r.applied_hosts.length} host(s)${r.skipped_hosts.length ? `, ${r.skipped_hosts.length} skipped` : ''}.`
            : 'Policy saved (no reachable member host to converge yet).';
          this.appDialog.notify(msg, 'info');
          done();
        },
        error: (e) => this.appDialog.notify(e?.error?.detail ?? 'Failed to create config policy.', 'error'),
      });
    });
  }

  /** {key: value} for keyvalue; for nested codecs a dotted key (section.key)
   * becomes a nested document. Mirrors the host editor's unflatten. */
  private unflattenSetting(key: string, value: unknown, deep: boolean): Record<string, unknown> {
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

  newNotification(ou: OUNode): void {
    // Load the fleet once so the scope selector can pick a host / group /
    // service / policy — not just this OU (Block P5).
    this.agentService.list().subscribe((agents: Agent[]) => {
      const data: NotificationOuDialogData = {
        ouId: ou.id, ouPath: ou.path, scopeType: 'ou',
        ...this.notificationPickers(agents),
      };
      const ref = this.dialog.open<NotificationOuDialogComponent, NotificationOuDialogData, NotificationRuleInput>(
        NotificationOuDialogComponent, { width: '460px', data },
      );
      ref.afterClosed().subscribe((input) => {
        if (!input) return;
        this.notification.createRule(input).subscribe(() => this.afterObjectChange(ou.id));
      });
    });
  }

  /** The scope-picker source lists for the notification dialog. */
  private notificationPickers(agents: Agent[]) {
    return {
      ous: this.ous().map((o) => ({ id: o.id, path: o.path })),
      groups: [...new Set(agents.flatMap((a) => a.groups ?? []))].sort(),
      hosts: agents.map((a) => a.name).sort(),
      plans: this.plans().map((p) => ({ id: p.id, label: p.display_name || p.name })),
    };
  }

  newHostGroup(ou: OUNode): void {
    const ref = this.dialog.open<HostGroupDialogComponent, HostGroupDialogData, HostGroupInput>(HostGroupDialogComponent, {
      width: '420px', data: { nodes: this.ous() },
    });
    ref.afterClosed().subscribe((input) => {
      if (!input) return;
      this.hostGroup.create({ ...input, ou_id: ou.id }).subscribe(() => this.afterObjectChange(ou.id));
    });
  }

  // --- orchestration (restored management: create a plan, link it to an OU) ---

  newOrchestrationPlan(ou: OUNode): void {
    const ref = this.dialog.open<OrchestrationPlanDialogComponent, undefined, OrchestrationPlanInput>(
      OrchestrationPlanDialogComponent, { width: '480px' },
    );
    ref.afterClosed().subscribe((input) => {
      if (!input) return;
      // Create the plan AND link it to the OU it was created under, so it
      // appears immediately as a policy object beneath that OU (previously a
      // freshly-created plan was invisible until separately linked).
      // Surface any failure — a duplicate policy name returns 409, which used
      // to be swallowed silently (looking like "you can only create one
      // policy" once a name was reused).
      const fail = (e: { error?: { detail?: string } }) =>
        this.appDialog.notify(e?.error?.detail ?? 'could not create the policy', 'error');
      this.orchestration.createPlan(input).subscribe({
        next: (plan) => {
          this.orchestration
            .createLink(plan.id, { target_type: 'ou', ou_id: ou.id, require_approval: true })
            .subscribe({
              next: () => {
                this.afterObjectChange(ou.id);
                this.reload(); // refresh the palette (plans list) too
              },
              error: fail,
            });
        },
        error: fail,
      });
    });
  }

  /** Block N2: create a brand-new policy that isn't linked anywhere yet —
   * it appears in the palette as "(unlinked)" and can be dragged onto an OU
   * or bound to a host/group later. Distinct from newOrchestrationPlan(ou),
   * which creates AND links under a specific OU. */
  /** "New Policy" authors a config policy AT A SCOPE through the full gpedit
   * editor (the new format): a policy set on an OU applies to every host under
   * it; a host's own config overrides it. Config policies live at scope, so a
   * scope must be selected. (The composite role/threshold policy still exists
   * via OrchestrationPlanDialog — newCompositePolicy.) */
  newPolicyUnlinked(): void {
    const sel = this.selected();
    let scope: PolicyGpeditDialogData['scope'] | null = null;
    if (sel?.kind === 'ou' && sel.ou) scope = { kind: 'ou', id: sel.ou.id, label: sel.ou.path };
    else if (sel?.kind !== 'ou' && sel?.obj?.kind === 'host_group') scope = { kind: 'group', id: sel.obj.id, label: sel.obj.label };
    if (!scope) {
      this.appDialog.notify('Select an OU (or host group) first — a policy is authored at a scope and applies to every host under it.', 'info');
      return;
    }
    this.dialog.open<PolicyGpeditDialogComponent, PolicyGpeditDialogData>(
      PolicyGpeditDialogComponent, { data: { scope } },
    ).afterClosed().subscribe(() => this.reload());
  }

  /** The former "New Policy" — a composite role/threshold/route policy object. */
  newCompositePolicy(): void {
    const ref = this.dialog.open<OrchestrationPlanDialogComponent, undefined, OrchestrationPlanInput>(
      OrchestrationPlanDialogComponent, { width: '480px' },
    );
    ref.afterClosed().subscribe((input) => {
      if (!input) return;
      const fail = (e: { error?: { detail?: string } }) => this.appDialog.notify(e?.error?.detail ?? 'could not create the policy', 'error');
      this.orchestration.createPlan(input).subscribe({ next: () => this.reload(), error: fail });
    });
  }

  /** Block N3: bind an existing policy within this OU — to the OU itself, or
   * (GPO-style) to a specific host or host group scoped under it. The dialog
   * offers a target selector + host/group picker; the backend already accepts
   * target_type host|group with agent_id|host_group_id. */
  linkPlan(ou: OUNode): void {
    this.agentService.list().subscribe((agents: Agent[]) => {
      this.hostGroup.list().subscribe((groups) => {
        const ref = this.dialog.open<OuLinkPlanDialogComponent, OuLinkPlanDialogData, OuLinkPlanResult>(
          OuLinkPlanDialogComponent,
          {
            width: '460px',
            data: {
              ouId: ou.id,
              ouPath: ou.path,
              hosts: agents.map((a) => ({ id: a.id, name: a.name })).sort((x, y) => x.name.localeCompare(y.name)),
              groups: groups.map((g) => ({ id: g.id, name: g.name })).sort((x, y) => x.name.localeCompare(y.name)),
            },
          },
        );
        ref.afterClosed().subscribe((res) => {
          if (!res) return;
          this.orchestration
            .createLink(res.plan_id, {
              target_type: res.target_type,
              ou_id: res.ou_id,
              agent_id: res.agent_id,
              host_group_id: res.host_group_id,
              enforced: res.enforced,
              auto_apply: res.auto_apply,
              require_approval: !res.auto_apply,
            })
            .subscribe({
              next: () => {
                // An OU-scoped link shows up as an object under the OU; host/
                // group-scoped links don't live under an OU node, so just
                // reload the palette to reflect the plan's now-linked state.
                if (res.target_type === 'ou') this.afterObjectChange(ou.id);
                else this.reload();
              },
              error: (e: { error?: { detail?: string } }) => this.appDialog.notify(e?.error?.detail ?? 'bind failed', 'error'),
            });
        });
      });
    });
  }

  // --- edit an existing object (Block L3c) ---

  editObject(row: TreeRow): void {
    const obj = row.obj!;
    const ou = this.ous().find((n) => n.id === row.ownerOuId);
    if (!ou) return;
    if (obj.kind === 'check_rule') {
      this.monitoring.listCheckRules().subscribe((rules) => {
        const rule = rules.find((r) => r.id === obj.id);
        if (!rule) return;
        const ref = this.dialog.open<ThresholdDialogComponent, ThresholdDialogData, CheckRuleInput>(ThresholdDialogComponent, {
          width: '460px', data: { ouId: ou.id, ouPath: ou.path, rule },
        });
        ref.afterClosed().subscribe((input) => {
          if (!input) return;
          this.monitoring.updateCheckRule(rule.id, input).subscribe(() => this.afterObjectChange(ou.id));
        });
      });
    } else if (obj.kind === 'notification') {
      this.notification.listRules().subscribe((rules) => {
        const rule = rules.find((r: NotificationRule) => r.id === obj.id);
        if (!rule) return;
        this.agentService.list().subscribe((agents: Agent[]) => {
          const ref = this.dialog.open<NotificationOuDialogComponent, NotificationOuDialogData, NotificationRuleInput>(
            NotificationOuDialogComponent,
            { width: '460px', data: { ouId: ou.id, ouPath: ou.path, rule, ...this.notificationPickers(agents) } },
          );
          ref.afterClosed().subscribe((input) => {
            if (!input) return;
            this.notification.updateRule(rule.id, input).subscribe(() => this.afterObjectChange(ou.id));
          });
        });
      });
    }
  }

  private afterObjectChange(ouId: string): void {
    this.expanded.update((e) => new Set(e).add(ouId));
    this.reloadObjects(ouId);
  }

  // --- object actions ---

  toggleEnforced(row: TreeRow): void {
    const obj = row.obj!;
    const next = !obj.enforced;
    const done = () => this.reloadObjects(row.ownerOuId!);
    if (obj.kind === 'check_rule') this.monitoring.patchCheckRule(obj.id, { enforced: next }).subscribe(done);
    else if (obj.kind === 'notification') this.notification.patchRule(obj.id, { enforced: next }).subscribe(done);
  }

  toggleEnabled(row: TreeRow): void {
    const obj = row.obj!;
    const next = !obj.enabled;
    const done = () => this.reloadObjects(row.ownerOuId!);
    if (obj.kind === 'check_rule') this.monitoring.patchCheckRule(obj.id, { enabled: next }).subscribe(done);
    else if (obj.kind === 'notification') this.notification.patchRule(obj.id, { enabled: next }).subscribe(done);
  }

  manageMembers(row: TreeRow): void {
    const obj = row.obj!;
    // AD-style membership editor: load the full group + all agents, then a
    // checkbox picker (replace-all, matching PUT /host-groups/{id}/members).
    this.hostGroup.list().subscribe((groups) => {
      const group = groups.find((g) => g.id === obj.id);
      if (!group) return;
      this.agentService.list().subscribe((agents: Agent[]) => {
        const ref = this.dialog.open<HostGroupMembersDialogComponent, HostGroupMembersDialogData, string[]>(
          HostGroupMembersDialogComponent, { width: '440px', data: { group, agents } },
        );
        ref.afterClosed().subscribe((agentIds) => {
          if (!agentIds) return;
          this.hostGroup.replaceMembers(group.id, agentIds).subscribe(() => this.reloadObjects(row.ownerOuId!));
        });
      });
    });
  }

  /** Unlink a threshold policy from just THIS OU (it keeps applying to any
   * other OUs it links to). Full reload since removing the primary OU promotes
   * another linked OU, which can move the object elsewhere in the tree. */
  unlinkFromOu(row: TreeRow): void {
    this.monitoring.removeOuLink(row.obj!.id, row.ownerOuId!).subscribe({
      next: () => this.reload(),
      error: (e) => this.appDialog.notify(e?.error?.detail ?? 'unlink failed', 'error'),
    });
  }

  deleteObject(row: TreeRow): void {
    const obj = row.obj!;
    const done = () => this.reloadObjects(row.ownerOuId!);
    if (obj.kind === 'check_rule') this.monitoring.deleteCheckRule(obj.id).subscribe(done);
    else if (obj.kind === 'notification') this.notification.deleteRule(obj.id).subscribe(done);
    else if (obj.kind === 'host_group') this.hostGroup.delete(obj.id).subscribe(done);
    else if (obj.kind === 'orchestration_link') this.orchestration.deleteLinkById(obj.id).subscribe(done);
    else if (obj.kind === 'config_policy') this.ouService.deleteConfigPolicy(obj.id).subscribe(done);
  }
}
