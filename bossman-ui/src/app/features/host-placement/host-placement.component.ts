import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { CdkContextMenuTrigger, CdkMenu, CdkMenuItem } from '@angular/cdk/menu';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { MatDialog } from '@angular/material/dialog';
import { Agent } from '../../core/models/agent.model';
import { OUNode } from '../../core/models/ou.model';
import { HostGroup, HostGroupInput } from '../../core/models/host-group.model';
import { CompiledHostState } from '../../core/models/orchestration.model';
import { GroupPolicyReport } from '../../core/models/host-group.model';
import { AgentService } from '../../core/services/agent.service';
import { OrchestrationService } from '../../core/services/orchestration.service';
import { OuService } from '../../core/services/ou.service';
import { HostGroupService } from '../../core/services/host-group.service';
import { OuNodeDialogComponent, OuNodeDialogData } from '../../shared/components/ou-node-dialog/ou-node-dialog.component';
import { HostGroupDialogComponent, HostGroupDialogData } from '../../shared/components/host-group-dialog/host-group-dialog.component';

interface Row {
  kind: 'ou' | 'host' | 'unassigned';
  depth: number;
  ou?: OUNode;
  host?: Agent;
  hasChildren?: boolean;
  expanded?: boolean;
}

/** A single applied-policy line in the host policy report, joining the
 * compiled orchestration plans with their explain provenance. */
interface AppliedPolicy {
  name: string;
  version: number | null;
  type: string;
  source: string; // 'global' | 'ou:/path' | 'group:<id>' | 'host'
}

/**
 * Host → OU placement tree (Block L3d / O) — sort servers (agents) into OUs
 * so it's visible which rules apply where. Left: a real expandable OU tree
 * with hosts nested under their OU (plus an "Unassigned" bucket); double-
 * click an OU to expand/collapse, right-click for "New sub-OU…" / "Create
 * group…". Drag a host onto an OU to place it. Right: a policy report for
 * the selected host (or host group) — the effective, GPO-resolved policies
 * with their origin, from GET /agents/{id}/desired-state (host) and
 * GET /host-groups/{id}/policy-report (group).
 */
@Component({
  selector: 'app-host-placement',
  standalone: true,
  imports: [CdkContextMenuTrigger, CdkMenu, CdkMenuItem, MatIconModule, MatButtonModule],
  template: `
    <div class="bm-page">
      <div class="bm-header">
        <h1>Host placement</h1>
        <span class="bm-header-actions">
          <button mat-stroked-button (click)="newGroup()">
            <mat-icon>group_add</mat-icon> New host group
          </button>
          <button mat-stroked-button (click)="createOu(null)">
            <mat-icon>create_new_folder</mat-icon> New root OU
          </button>
        </span>
      </div>
      <p class="bm-sub">
        Sort servers into OUs — a host inherits every rule on its OU path. Double-click an OU to
        expand, right-click for sub-OUs and groups. Select a host or group to see its policy report.
      </p>

      <div class="bm-split">
        <div class="bm-tree">
          @for (row of rows(); track rowKey(row)) {
            @if (row.kind === 'ou' || row.kind === 'unassigned') {
              <div
                class="bm-node bm-ou"
                [class.bm-drop-target]="dropTargetId() === (row.kind === 'unassigned' ? '__none__' : row.ou!.id)"
                [style.paddingLeft.px]="8 + row.depth * 18"
                (dragover)="onDragOver(row.kind === 'unassigned' ? null : row.ou!.id, $event)"
                (dragleave)="onDragLeave(row.kind === 'unassigned' ? null : row.ou!.id)"
                (drop)="onDrop(row.kind === 'unassigned' ? null : row.ou!.id, $event)"
                (dblclick)="row.kind === 'ou' && toggleExpand(row.ou!)"
                [cdkContextMenuTriggerFor]="row.kind === 'ou' ? ouMenu : null"
                (contextmenu)="row.kind === 'ou' && ctxOu.set(row.ou!)"
              >
                @if (row.kind === 'ou') {
                  <span class="bm-twisty" (click)="toggleExpand(row.ou!); $event.stopPropagation()">
                    {{ row.hasChildren ? (row.expanded ? '▾' : '▸') : '·' }}
                  </span>
                } @else {
                  <span class="bm-twisty">·</span>
                }
                <mat-icon class="bm-ou-icon">{{ row.kind === 'unassigned' ? 'help_outline' : 'folder' }}</mat-icon>
                <span class="bm-label">{{ row.kind === 'unassigned' ? 'Unassigned' : row.ou!.name }}</span>
              </div>
            } @else {
              <div class="bm-node bm-host" [class.bm-selected]="selectedHost()?.id === row.host!.id"
                   [style.paddingLeft.px]="8 + row.depth * 18" (click)="selectHost(row.host!)"
                   draggable="true" (dragstart)="onHostDragStart(row.host!, $event)" (dragend)="onHostDragEnd()">
                <span class="bm-twisty">·</span>
                <mat-icon class="bm-host-icon">dns</mat-icon>
                <span class="bm-label">{{ row.host!.name }}</span>
                <span class="bm-drag-hint">drag onto an OU →</span>
              </div>
            }
          }
          @if (!hosts().length) {
            <p class="bm-empty">No hosts enrolled yet.</p>
          }

          <!-- Host groups: cross-cutting membership (not nested in the OU tree);
               select one to see its policy report. -->
          @if (groups().length) {
            <div class="bm-groups-head">Host groups</div>
            @for (g of groups(); track g.id) {
              <div class="bm-node bm-group" [class.bm-selected]="selectedGroup()?.id === g.id"
                   (click)="selectGroup(g)">
                <span class="bm-twisty">·</span>
                <mat-icon class="bm-host-icon">workspaces</mat-icon>
                <span class="bm-label">{{ g.name }}</span>
                <span class="bm-drag-hint">{{ g.member_agent_ids.length }} members</span>
              </div>
            }
          }
        </div>

        <div class="bm-detail">
          @if (selectedHost(); as h) {
            <h2>{{ h.name }}</h2>
            @if (desired(); as d) {
              <table class="bm-kv">
                <tr><th>OU</th><td>{{ d.state.host.ou ?? '(unassigned)' }}</td></tr>
                <tr><th>Generation</th><td>{{ d.generation }}</td></tr>
              </table>

              <h3>Applied policies</h3>
              @if (appliedPolicies().length) {
                <table class="bm-report">
                  <thead><tr><th>Policy</th><th>Type</th><th>Ver</th><th>Origin</th></tr></thead>
                  <tbody>
                    @for (p of appliedPolicies(); track p.name + p.source) {
                      <tr>
                        <td>{{ p.name }}</td>
                        <td class="bm-dim">{{ p.type }}</td>
                        <td class="bm-dim">{{ p.version ?? '—' }}</td>
                        <td><span class="bm-origin">{{ originLabel(p.source) }}</span></td>
                      </tr>
                    }
                  </tbody>
                </table>
              } @else { <p class="bm-empty">No policies apply to this host.</p> }

              <h3>Effective checks</h3>
              @if (d.state.monitoring.checks.length) {
                <ul class="bm-list">
                  @for (c of d.state.monitoring.checks; track c) { <li>{{ c }}</li> }
                </ul>
              } @else { <p class="bm-empty">No checks from OU rules yet.</p> }
              <h3>Roles</h3>
              @if (d.state.orchestration.roles.length) {
                <ul class="bm-list">
                  @for (r of d.state.orchestration.roles; track r) { <li>{{ r }}</li> }
                </ul>
              } @else { <p class="bm-empty">No orchestration roles.</p> }

              @if (ouPath().length) {
                <h3>OU inheritance path</h3>
                <div class="bm-crumbs">
                  @for (p of ouPath(); track p; let last = $last) {
                    <span class="bm-crumb">{{ p }}</span>@if (!last) { <span class="bm-crumb-sep">›</span> }
                  }
                </div>
              }
            } @else {
              <p class="bm-empty">Loading desired state…</p>
            }
          } @else if (selectedGroup(); as g) {
            <h2>{{ g.name }} <span class="bm-dim">(host group)</span></h2>
            @if (groupReport(); as gr) {
              <table class="bm-kv">
                <tr><th>Members</th><td>{{ gr.member_count }}</td></tr>
                <tr><th>Distinct policies</th><td>{{ gr.policies.length }}</td></tr>
              </table>
              <h3>Policies applying to members</h3>
              @if (gr.policies.length) {
                <table class="bm-report">
                  <thead><tr><th>Policy</th><th>Type</th><th>Ver</th><th>Applies to</th></tr></thead>
                  <tbody>
                    @for (p of gr.policies; track p.name) {
                      <tr>
                        <td>{{ p.name }}</td>
                        <td class="bm-dim">{{ p.type }}</td>
                        <td class="bm-dim">{{ p.version ?? '—' }}</td>
                        <td class="bm-dim">{{ p.member_count }}/{{ gr.member_count }} hosts</td>
                      </tr>
                    }
                  </tbody>
                </table>
              } @else { <p class="bm-empty">No policies apply to this group's members.</p> }
            } @else {
              <p class="bm-empty">Loading group policy report…</p>
            }
          } @else {
            <p class="bm-empty">Select a host or group to see which policies apply.</p>
          }
        </div>
      </div>
    </div>

    <!-- OU context menu -->
    <ng-template #ouMenu>
      <div class="bm-menu" cdkMenu>
        <button class="bm-menu-item" cdkMenuItem (click)="createOu(ctxOu()!.id)">New sub-OU…</button>
        <button class="bm-menu-item" cdkMenuItem (click)="createGroup(ctxOu()!)">Create group…</button>
      </div>
    </ng-template>
  `,
  styles: [
    `
      .bm-page { padding: 24px; max-width: 1100px; margin: 0 auto; }
      .bm-header { display: flex; align-items: center; gap: 16px; }
      .bm-header h1 { margin: 0; }
      .bm-header-actions { margin-left: auto; display: flex; gap: 8px; }
      .bm-sub { opacity: 0.7; margin-top: 4px; }
      .bm-split { display: flex; gap: 16px; align-items: flex-start; margin-top: 12px; }
      .bm-tree, .bm-detail {
        border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; min-height: 340px;
      }
      .bm-tree { flex: 1 1 50%; padding: 6px 0; overflow-x: auto; }
      .bm-detail { flex: 1 1 50%; padding: 12px 16px; }
      .bm-node { display: flex; align-items: center; gap: 6px; padding: 3px 10px; white-space: nowrap; user-select: none; }
      .bm-ou { cursor: default; }
      .bm-host, .bm-group { cursor: pointer; }
      .bm-host { cursor: grab; }
      .bm-host:active { cursor: grabbing; }
      .bm-host:hover, .bm-group:hover, .bm-ou:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
      .bm-selected { background: color-mix(in srgb, var(--bm-green) 16%, transparent); }
      .bm-drop-target {
        outline: 2px solid var(--bm-green); outline-offset: -2px;
        background: color-mix(in srgb, var(--bm-green) 12%, transparent);
      }
      .bm-twisty { width: 14px; text-align: center; opacity: 0.7; }
      .bm-ou-icon, .bm-host-icon { font-size: 18px; height: 18px; width: 18px; }
      .bm-ou-icon { opacity: 0.8; }
      .bm-host-icon { opacity: 0.65; }
      .bm-label { font-size: 13.5px; flex: 0 0 auto; }
      .bm-groups-head {
        font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; opacity: 0.55;
        padding: 10px 12px 2px; margin-top: 6px; border-top: 1px solid var(--mat-sys-outline-variant);
      }
      .bm-drag-hint { margin-left: auto; font-size: 11px; opacity: 0; transition: opacity 0.15s; padding-left: 12px; }
      .bm-host:hover .bm-drag-hint, .bm-group .bm-drag-hint { opacity: 0.5; }
      .bm-empty { opacity: 0.7; padding: 4px 0; }
      .bm-dim { opacity: 0.6; }
      .bm-kv { border-collapse: collapse; margin: 8px 0; }
      .bm-kv th { text-align: left; opacity: 0.7; padding: 4px 16px 4px 0; font-weight: 500; }
      .bm-list { margin: 4px 0 12px; padding-left: 18px; }
      .bm-report { border-collapse: collapse; width: 100%; margin: 4px 0 12px; font-size: 13px; }
      .bm-report th { text-align: left; opacity: 0.6; font-weight: 500; padding: 3px 10px 3px 0; }
      .bm-report td { padding: 3px 10px 3px 0; border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-origin {
        font-size: 11.5px; padding: 1px 8px; border-radius: 999px;
        background: color-mix(in srgb, var(--bm-green) 18%, transparent);
      }
      .bm-crumbs { display: flex; flex-wrap: wrap; align-items: center; gap: 4px; margin: 4px 0 12px; }
      .bm-crumb { font-size: 12.5px; opacity: 0.85; }
      .bm-crumb-sep { opacity: 0.4; }
      h3 { margin: 12px 0 4px; font-size: 13px; opacity: 0.8; }
      .bm-menu {
        background: var(--mat-sys-surface-container-high, #2a2a2a);
        border: 1px solid var(--mat-sys-outline-variant);
        border-radius: 6px; padding: 4px; min-width: 160px;
        box-shadow: 0 4px 16px rgba(0,0,0,0.4);
      }
      .bm-menu-item {
        display: block; width: 100%; text-align: left; background: none; border: none;
        color: inherit; padding: 7px 12px; font: inherit; cursor: pointer; border-radius: 4px;
      }
      .bm-menu-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    `,
  ],
})
export class HostPlacementComponent implements OnInit {
  private ouService = inject(OuService);
  private agentService = inject(AgentService);
  private orchestration = inject(OrchestrationService);
  private hostGroup = inject(HostGroupService);
  private dialog = inject(MatDialog);

  ous = signal<OUNode[]>([]);
  hosts = signal<Agent[]>([]);
  groups = signal<HostGroup[]>([]);
  expanded = signal<Set<string>>(new Set());
  selectedHost = signal<Agent | null>(null);
  selectedGroup = signal<HostGroup | null>(null);
  desired = signal<CompiledHostState | null>(null);
  groupReport = signal<GroupPolicyReport | null>(null);
  ctxOu = signal<OUNode | null>(null);
  dragHostId = signal<string | null>(null);
  dropTargetId = signal<string | null>(null);

  private childrenByParent = computed(() => {
    const map = new Map<string | null, OUNode[]>();
    for (const ou of this.ous()) {
      const list = map.get(ou.parent_id) ?? [];
      list.push(ou);
      map.set(ou.parent_id, list);
    }
    for (const list of map.values()) list.sort((a, b) => a.name.localeCompare(b.name));
    return map;
  });

  private hostsByOu = computed(() => {
    const map = new Map<string, Agent[]>();
    const unassigned: Agent[] = [];
    for (const h of this.hosts()) {
      if (h.ou_id) {
        const list = map.get(h.ou_id) ?? [];
        list.push(h);
        map.set(h.ou_id, list);
      } else {
        unassigned.push(h);
      }
    }
    for (const list of map.values()) list.sort((a, b) => a.name.localeCompare(b.name));
    unassigned.sort((a, b) => a.name.localeCompare(b.name));
    return { map, unassigned };
  });

  rows = computed<Row[]>(() => {
    const out: Row[] = [];
    const byParent = this.childrenByParent();
    const { map: byOu, unassigned } = this.hostsByOu();
    const exp = this.expanded();
    const walk = (parentId: string | null, depth: number) => {
      for (const ou of byParent.get(parentId) ?? []) {
        const childOus = byParent.get(ou.id) ?? [];
        const ouHosts = byOu.get(ou.id) ?? [];
        const isExpanded = exp.has(ou.id);
        out.push({ kind: 'ou', ou, depth, hasChildren: childOus.length > 0 || ouHosts.length > 0, expanded: isExpanded });
        if (isExpanded) {
          for (const h of ouHosts) out.push({ kind: 'host', host: h, depth: depth + 1 });
          walk(ou.id, depth + 1);
        }
      }
    };
    walk(null, 0);
    if (unassigned.length) {
      out.push({ kind: 'unassigned', depth: 0 });
      for (const h of unassigned) out.push({ kind: 'host', host: h, depth: 1 });
    }
    return out;
  });

  /** The applied-policy report rows for the selected host: the compiled
   * plans joined with their explain provenance (source OU/group/host). */
  appliedPolicies = computed<AppliedPolicy[]>(() => {
    const d = this.desired();
    if (!d) return [];
    const explain = (d.explain ?? {}) as { assignments?: { plan: string; source: string; version: number | null }[] };
    const sourceByPlan = new Map((explain.assignments ?? []).map((a) => [a.plan, a.source] as const));
    return d.state.orchestration.plans.map((p) => ({
      name: p.name,
      version: p.version,
      type: p.type,
      source: sourceByPlan.get(p.name) ?? 'ou',
    }));
  });

  ouPath = computed<string[]>(() => {
    const d = this.desired();
    const explain = (d?.explain ?? {}) as { ou_path?: string[] };
    return explain.ou_path ?? [];
  });

  ngOnInit(): void {
    this.reload();
  }

  private reload(): void {
    this.ouService.list().subscribe((o) => {
      this.ous.set(o);
      // Expand every OU by default so the placement tree is fully visible
      // (it's a placement view, not a browse-heavy console).
      this.expanded.set(new Set(o.map((n) => n.id)));
    });
    this.agentService.list().subscribe((a) => this.hosts.set(a));
    this.hostGroup.list().subscribe((g) => this.groups.set(g));
  }

  rowKey(row: Row): string {
    if (row.kind === 'host') return `h:${row.host!.id}`;
    if (row.kind === 'unassigned') return 'unassigned';
    return `ou:${row.ou!.id}`;
  }

  toggleExpand(ou: OUNode): void {
    const exp = new Set(this.expanded());
    if (exp.has(ou.id)) exp.delete(ou.id);
    else exp.add(ou.id);
    this.expanded.set(exp);
  }

  selectHost(host: Agent): void {
    this.selectedGroup.set(null);
    this.groupReport.set(null);
    this.selectedHost.set(host);
    this.desired.set(null);
    this.orchestration.desiredState(host.id).subscribe((d) => this.desired.set(d));
  }

  selectGroup(group: HostGroup): void {
    this.selectedHost.set(null);
    this.desired.set(null);
    this.selectedGroup.set(group);
    this.groupReport.set(null);
    this.hostGroup.policyReport(group.id).subscribe((r) => this.groupReport.set(r));
  }

  /** Turn a compiler `source` string into a human origin label. */
  originLabel(source: string): string {
    if (source === 'global') return 'Global';
    if (source === 'host') return 'This host';
    if (source.startsWith('ou:')) return 'OU ' + source.slice(3);
    if (source.startsWith('group:')) {
      const id = source.slice(6);
      return 'Group ' + (this.groups().find((g) => g.id === id)?.name ?? id);
    }
    return source;
  }

  // --- OU / group creation ---

  createOu(parentId: string | null): void {
    const ref = this.dialog.open<OuNodeDialogComponent, OuNodeDialogData, { name: string; parent_id?: string | null }>(
      OuNodeDialogComponent,
      { width: '420px', data: { nodes: this.ous() } },
    );
    ref.afterClosed().subscribe((input) => {
      if (!input) return;
      this.ouService.create({ name: input.name, parent_id: parentId ?? input.parent_id ?? null }).subscribe(() => {
        if (parentId) this.expanded.update((e) => new Set(e).add(parentId));
        this.reload();
      });
    });
  }

  createGroup(ou: OUNode): void {
    const ref = this.dialog.open<HostGroupDialogComponent, HostGroupDialogData, HostGroupInput>(HostGroupDialogComponent, {
      width: '420px', data: { nodes: this.ous() },
    });
    ref.afterClosed().subscribe((input) => {
      if (!input) return;
      this.hostGroup.create({ ...input, ou_id: ou.id }).subscribe(() => this.reload());
    });
  }

  /** Top-level "New host group" — the OU is chosen in the dialog (optional),
   * so groups can be created without right-clicking a specific OU first. */
  newGroup(): void {
    const ref = this.dialog.open<HostGroupDialogComponent, HostGroupDialogData, HostGroupInput>(HostGroupDialogComponent, {
      width: '420px', data: { nodes: this.ous() },
    });
    ref.afterClosed().subscribe((input) => {
      if (!input) return;
      this.hostGroup.create(input).subscribe(() => this.reload());
    });
  }

  moveHost(host: Agent, ouId: string | null): void {
    if ((host.ou_id ?? null) === (ouId ?? null)) return;
    this.ouService.assignAgent(host.id, ouId).subscribe(() => {
      this.hosts.update((hs) => hs.map((h) => (h.id === host.id ? { ...h, ou_id: ouId } : h)));
      if (ouId) this.expanded.update((e) => new Set(e).add(ouId));
      if (this.selectedHost()?.id === host.id) this.selectHost({ ...host, ou_id: ouId });
    });
  }

  // --- drag-and-drop placement ---

  onHostDragStart(host: Agent, event: DragEvent): void {
    this.dragHostId.set(host.id);
    event.dataTransfer?.setData('text/plain', host.id);
    if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move';
  }

  onHostDragEnd(): void {
    this.dragHostId.set(null);
    this.dropTargetId.set(null);
  }

  onDragOver(ouId: string | null, event: DragEvent): void {
    if (!this.dragHostId()) return;
    event.preventDefault();
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'move';
    this.dropTargetId.set(ouId ?? '__none__');
  }

  onDragLeave(ouId: string | null): void {
    if (this.dropTargetId() === (ouId ?? '__none__')) this.dropTargetId.set(null);
  }

  onDrop(ouId: string | null, event: DragEvent): void {
    event.preventDefault();
    const hostId = this.dragHostId();
    this.dropTargetId.set(null);
    this.dragHostId.set(null);
    if (!hostId) return;
    const host = this.hosts().find((h) => h.id === hostId);
    if (host) this.moveHost(host, ouId);
  }
}
