import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { CdkMenu, CdkMenuItem, CdkContextMenuTrigger } from '@angular/cdk/menu';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { MatDialog } from '@angular/material/dialog';
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
import { SystemSettingsService } from '../../core/services/system-settings.service';
import { OuNodeDialogComponent, OuNodeDialogData } from '../../shared/components/ou-node-dialog/ou-node-dialog.component';
import { HostGroupDialogComponent, HostGroupDialogData } from '../../shared/components/host-group-dialog/host-group-dialog.component';
import {
  HostGroupMembersDialogComponent,
  HostGroupMembersDialogData,
} from '../../shared/components/host-group-members-dialog/host-group-members-dialog.component';
import { ThresholdDialogComponent, ThresholdDialogData } from '../../shared/components/threshold-dialog/threshold-dialog.component';
import { OrchestrationPlanDialogComponent } from '../../shared/components/orchestration-plan-dialog/orchestration-plan-dialog.component';
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
  kind: 'check_rule' | 'notification' | 'host_group' | 'orchestration_link' | 'plan';
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
  imports: [CdkMenu, CdkMenuItem, CdkContextMenuTrigger, MatIconModule, MatButtonModule, MatSlideToggleModule],
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
                  [cdkContextMenuTriggerFor]="objMenu"
                  (contextmenu)="ctx.set(row)"
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
          <div class="bm-palette-head">Policies — drag onto an OU to link</div>
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
              <p class="bm-hint">Right-click to add OUs/objects, toggle Block Inheritance, or delete.</p>
            } @else {
              <h2>{{ sel.obj!.label }}</h2>
              <table class="bm-kv">
                <tr><th>Kind</th><td>{{ sel.obj!.kind }}</td></tr>
                <tr><th>Enforced</th><td>{{ sel.obj!.enforced ? 'yes' : 'no' }}</td></tr>
                <tr><th>Enabled</th><td>{{ sel.obj!.enabled ? 'yes' : 'no' }}</td></tr>
              </table>
              <p class="bm-hint">Right-click to toggle Enforced / Enabled or delete.</p>
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
        <button class="bm-menu-item" cdkMenuItem (click)="newThreshold(ctx()!.ou!)">New Threshold…</button>
        <button class="bm-menu-item" cdkMenuItem (click)="newNotification(ctx()!.ou!)">New Notification…</button>
        <button class="bm-menu-item" cdkMenuItem (click)="newHostGroup(ctx()!.ou!)">New Host Group…</button>
        <button class="bm-menu-item" cdkMenuItem (click)="linkPlan(ctx()!.ou!)">Link Orchestration Plan…</button>
        <div class="bm-menu-sep"></div>
        <button class="bm-menu-item" cdkMenuItem (click)="newOrchestrationPlan(ctx()!.ou!)">New Orchestration Plan…</button>
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
        @if (ctx()?.obj?.kind === 'host_group') {
          <button class="bm-menu-item" cdkMenuItem (click)="manageMembers(ctx()!)">Members…</button>
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
      }
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
  private dialog = inject(MatDialog);

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
      for (const ou of ous) {
        this.ouService.objects(ou.id).subscribe((objs) => {
          this.objectsByOu.update((m) => new Map(m).set(ou.id, objs));
          if (objs.length) this.expanded.update((e) => new Set(e).add(ou.id));
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
    return { check_rule: 'speed', notification: 'notifications', host_group: 'dns', orchestration_link: 'widgets' }[kind];
  }

  select(row: TreeRow): void {
    this.selected.set(row);
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
      orchestration_link: 'widgets', plan: 'widgets',
    }[kind];
  }

  /** A policy dragged from the palette (any type). */
  onPolicyDragStart(item: PaletteItem, event: DragEvent): void {
    this.dragPolicy.set(item);
    event.dataTransfer?.setData('text/plain', item.id);
    if (event.dataTransfer) event.dataTransfer.effectAllowed = 'link';
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
      error: (e) => alert(e?.error?.detail ?? 'move failed'),
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
    const fail = (e: { error?: { detail?: string } }) => alert(e?.error?.detail ?? 'link failed');
    switch (item.kind) {
      case 'check_rule':
        this.monitoring.patchCheckRule(item.id, { scope_ou_id: ouId }).subscribe({ next: done, error: fail });
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
      error: (e) => alert(e?.error?.detail ?? 'move failed'),
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
    this.ouService.delete(ou.id).subscribe({ next: () => this.reload(), error: (e) => alert(e?.error?.detail ?? 'delete failed') });
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

  newNotification(ou: OUNode): void {
    const ref = this.dialog.open<NotificationOuDialogComponent, NotificationOuDialogData, NotificationRuleInput>(
      NotificationOuDialogComponent,
      { width: '460px', data: { ouId: ou.id, ouPath: ou.path } },
    );
    ref.afterClosed().subscribe((input) => {
      if (!input) return;
      this.notification.createRule(input).subscribe(() => this.afterObjectChange(ou.id));
    });
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
      this.orchestration.createPlan(input).subscribe((plan) => {
        this.orchestration
          .createLink(plan.id, { target_type: 'ou', ou_id: ou.id, require_approval: true })
          .subscribe(() => this.afterObjectChange(ou.id));
      });
    });
  }

  linkPlan(ou: OUNode): void {
    const ref = this.dialog.open<OuLinkPlanDialogComponent, OuLinkPlanDialogData, OuLinkPlanResult>(OuLinkPlanDialogComponent, {
      width: '460px', data: { ouId: ou.id, ouPath: ou.path },
    });
    ref.afterClosed().subscribe((res) => {
      if (!res) return;
      this.orchestration
        .createLink(res.plan_id, {
          target_type: 'ou', ou_id: ou.id, enforced: res.enforced,
          auto_apply: res.auto_apply, require_approval: !res.auto_apply,
        })
        .subscribe(() => this.afterObjectChange(ou.id));
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
        const ref = this.dialog.open<NotificationOuDialogComponent, NotificationOuDialogData, NotificationRuleInput>(
          NotificationOuDialogComponent, { width: '460px', data: { ouId: ou.id, ouPath: ou.path, rule } },
        );
        ref.afterClosed().subscribe((input) => {
          if (!input) return;
          this.notification.updateRule(rule.id, input).subscribe(() => this.afterObjectChange(ou.id));
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

  deleteObject(row: TreeRow): void {
    const obj = row.obj!;
    const done = () => this.reloadObjects(row.ownerOuId!);
    if (obj.kind === 'check_rule') this.monitoring.deleteCheckRule(obj.id).subscribe(done);
    else if (obj.kind === 'notification') this.notification.deleteRule(obj.id).subscribe(done);
    else if (obj.kind === 'host_group') this.hostGroup.delete(obj.id).subscribe(done);
    else if (obj.kind === 'orchestration_link') this.orchestration.deleteLinkById(obj.id).subscribe(done);
  }
}
