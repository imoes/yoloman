import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { Subscription } from 'rxjs';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatTabsModule } from '@angular/material/tabs';
import { MatSnackBar } from '@angular/material/snack-bar';
import {
  ActionInfo, ActionsResponse, ApiResource, Inventory, K8sEvent, KubernetesCluster, KubernetesService, LogsResponse, ObjectDetail, ObjectRow,
  STATE_LABEL, StateInfo, stateBadge,
} from '../../core/services/kubernetes.service';
import { K8sDeleteResult, ResourceDiff, ResourceRef, ResourceService } from '../../core/services/resource.service';
import { ResourceInspectorComponent } from '../../shared/resource-inspector/resource-inspector.component';
import { formatDuration } from '../../shared/format.util';
import { BlockedReasonDirective } from '../../shared/blocked-reason/blocked-reason.directive';

/** One node of the explorer's source list: a kind to list, or a built-in page. */
interface TreeNode { id: string; title: string; kind?: string; page?: 'overview' | 'apps' | 'helm' | 'all'; }
interface TreeGroup { id: string; title: string; icon: string; nodes: TreeNode[]; }

/** The Rancher grouping, cut down to what a newcomer reaches for; every other kind lives under "All kinds". */
const TREE: TreeGroup[] = [
  { id: 'cluster', title: 'Cluster', icon: 'hub', nodes: [
    { id: 'overview', title: 'Overview', page: 'overview' },
    { id: 'nodes', title: 'Nodes', kind: 'nodes' }, { id: 'namespaces', title: 'Namespaces', kind: 'namespaces' },
    { id: 'events', title: 'Events', kind: 'events' },
    { id: 'quotas', title: 'Resource quotas', kind: 'resourcequotas' }, { id: 'limits', title: 'Limit ranges', kind: 'limitranges' } ] },
  { id: 'apps', title: 'Applications', icon: 'apps', nodes: [
    { id: 'applications', title: 'Applications', page: 'apps' }, { id: 'helm', title: 'Helm releases', page: 'helm' } ] },
  { id: 'workloads', title: 'Workloads', icon: 'deployed_code', nodes: [
    { id: 'deployments', title: 'Deployments', kind: 'deployments' }, { id: 'statefulsets', title: 'StatefulSets', kind: 'statefulsets' },
    { id: 'daemonsets', title: 'DaemonSets', kind: 'daemonsets' }, { id: 'jobs', title: 'Jobs', kind: 'jobs' },
    { id: 'cronjobs', title: 'CronJobs', kind: 'cronjobs' }, { id: 'pods', title: 'Pods', kind: 'pods' } ] },
  { id: 'config', title: 'Configuration', icon: 'tune', nodes: [
    { id: 'configmaps', title: 'ConfigMaps', kind: 'configmaps' }, { id: 'secrets', title: 'Secrets', kind: 'secrets' } ] },
  { id: 'network', title: 'Network', icon: 'lan', nodes: [
    { id: 'services', title: 'Services', kind: 'services' }, { id: 'ingresses', title: 'Ingresses', kind: 'ingresses' },
    { id: 'netpol', title: 'Network policies', kind: 'networkpolicies' } ] },
  { id: 'storage', title: 'Storage', icon: 'storage', nodes: [
    { id: 'pvcs', title: 'Volume claims', kind: 'persistentvolumeclaims' }, { id: 'pvs', title: 'Volumes', kind: 'persistentvolumes' },
    { id: 'storageclasses', title: 'Storage classes', kind: 'storageclasses' } ] },
  { id: 'access', title: 'Access', icon: 'admin_panel_settings', nodes: [
    { id: 'serviceaccounts', title: 'Service accounts', kind: 'serviceaccounts' }, { id: 'roles', title: 'Roles', kind: 'roles' },
    { id: 'rolebindings', title: 'Role bindings', kind: 'rolebindings' }, { id: 'clusterroles', title: 'Cluster roles', kind: 'clusterroles' },
    { id: 'clusterrolebindings', title: 'Cluster role bindings', kind: 'clusterrolebindings' } ] },
  { id: 'more', title: 'Everything else', icon: 'category', nodes: [ { id: 'all', title: 'All object kinds', page: 'all' } ] },
];

/** Per-kind summary columns (key in `summary`, header). Kinds not listed get a generic facts column. */
const COLUMNS: Record<string, [string, string][]> = {
  Deployment: [['ready', 'Ready'], ['up_to_date', 'Up to date'], ['available', 'Available'], ['images', 'Images']],
  StatefulSet: [['ready', 'Ready'], ['images', 'Images']], ReplicaSet: [['ready', 'Ready'], ['images', 'Images']],
  DaemonSet: [['ready', 'Ready'], ['images', 'Images']],
  Job: [['completions', 'Completions'], ['active', 'Active'], ['failed', 'Failed'], ['images', 'Images']],
  CronJob: [['schedule', 'Schedule'], ['suspend', 'Suspended'], ['active', 'Active'], ['last_schedule', 'Last run']],
  Pod: [['ready', 'Ready'], ['restarts', 'Restarts'], ['node', 'Node'], ['ip', 'IP'], ['qos', 'QoS'], ['owner', 'Owner']],
  Service: [['type', 'Type'], ['cluster_ip', 'Cluster IP'], ['ports', 'Ports'], ['external', 'External']],
  Ingress: [['class', 'Class'], ['hosts', 'Hosts'], ['tls', 'TLS'], ['address', 'Address']],
  ConfigMap: [['keys', 'Keys'], ['immutable', 'Immutable']], Secret: [['type', 'Type'], ['keys', 'Keys']],
  PersistentVolumeClaim: [['phase', 'Phase'], ['capacity', 'Capacity'], ['access_modes', 'Access'], ['storage_class', 'Class'], ['volume', 'Volume']],
  PersistentVolume: [['phase', 'Phase'], ['capacity', 'Capacity'], ['access_modes', 'Access'], ['reclaim', 'Reclaim'], ['claim', 'Claim']],
  StorageClass: [['provisioner', 'Provisioner'], ['reclaim', 'Reclaim'], ['binding_mode', 'Binding'], ['default', 'Default']],
  Node: [['roles', 'Roles'], ['kubelet_version', 'Version'], ['internal_ip', 'IP'], ['taints', 'Taints'], ['unschedulable', 'Cordoned']],
  Namespace: [['phase', 'Phase'], ['pod_security', 'Pod security']],
  HorizontalPodAutoscaler: [['target', 'Target'], ['min', 'Min'], ['max', 'Max'], ['current', 'Current'], ['desired', 'Desired']],
  Event: [['type', 'Type'], ['reason', 'Reason'], ['object', 'Object'], ['message', 'Message'], ['count', 'Count']],
  ServiceAccount: [['automount', 'Automount token'], ['image_pull_secrets', 'Pull secrets']],
  Role: [['rules', 'Rules']], ClusterRole: [['rules', 'Rules']],
  RoleBinding: [['role', 'Role'], ['subjects', 'Subjects']], ClusterRoleBinding: [['role', 'Role'], ['subjects', 'Subjects']],
  NetworkPolicy: [['pod_selector', 'Pod selector'], ['policy_types', 'Types']],
  ResourceQuota: [['hard', 'Hard'], ['used', 'Used']], LimitRange: [['limits', 'Limits']],
  PodDisruptionBudget: [['min_available', 'Min available'], ['max_unavailable', 'Max unavailable'], ['disruptions_allowed', 'Allowed'], ['healthy', 'Healthy']],
};

const WORKLOAD_KINDS = new Set(['Deployment', 'StatefulSet', 'DaemonSet', 'ReplicaSet', 'Job']);

/**
 * THE KUBERNETES EXPLORER — source list → list → inspector, for one registered cluster.
 *
 * Left: the object kinds grouped by concern (Rancher's grouping, cut to a newcomer's needs; everything
 * else under "All object kinds", so nothing the API server knows is hidden). Middle: one list per kind,
 * each row with the EXHAUSTIVE state and the reason behind it. Right: the selected object — spec (desired)
 * and status (observed) kept apart, the pods it owns, its events (the "why"), logs, and the generic Resource
 * inspector (Values / Preview / Generations) for the four verbs. The etcd key is shown to explain where
 * the state lives; it is never read or written — the API server is the only writer.
 */
@Component({
  selector: 'app-kubernetes-explorer',
  standalone: true,
  imports: [BlockedReasonDirective, FormsModule, RouterLink, MatButtonModule, MatIconModule, MatTabsModule, ResourceInspectorComponent],
  template: `
    <div class="bm-k8s">
      <!-- ── source list ─────────────────────────────────────────────── -->
      <aside class="bm-scope">
        <div class="bm-scope-head">
          <mat-icon>hub</mat-icon>
          <div>
            <div class="bm-scope-title">{{ cluster()?.name || '…' }}</div>
            <div class="bm-dim bm-small">
              {{ cluster()?.server_version || 'version unknown' }} · via {{ cluster()?.agent_name }}
              · <a routerLink="/kubernetes">all clusters</a>
            </div>
          </div>
        </div>
        @if (cluster(); as c) {
          @if (c.reachability !== 'reachable') {
            <div class="bm-note bm-note--why"><strong>{{ c.reachability }}</strong>: {{ c.unreachable_reason || 'not probed yet' }}
              — what you see below is the last cached inventory{{ inventoryAge() ? ' (' + inventoryAge() + ')' : '' }}.</div>
          }
        }
        <div class="bm-nsrow">
          <label class="bm-small bm-dim" for="k8s-ns">Namespace</label>
          <select id="k8s-ns" [ngModel]="namespace()" (ngModelChange)="setNamespace($event)">
            <option value="">all namespaces</option>
            @for (ns of namespaces(); track ns.name) { <option [value]="ns.name">{{ ns.name }}</option> }
          </select>
        </div>
        @for (g of tree; track g.id) {
          <div class="bm-group">
            <div class="bm-group-head" (click)="toggle(g.id)">
              <mat-icon class="bm-chev">{{ open().has(g.id) ? 'expand_more' : 'chevron_right' }}</mat-icon>
              <mat-icon class="bm-gicon">{{ g.icon }}</mat-icon>
              <span class="bm-gname">{{ g.title }}</span>
            </div>
            @if (open().has(g.id)) {
              @for (n of g.nodes; track n.id) {
                <button class="bm-node" [class.bm-sel]="nodeId() === n.id" (click)="selectNode(n)">
                  <mat-icon>{{ nodeId() === n.id ? 'folder_open' : 'description' }}</mat-icon>
                  {{ n.title }}
                  @if (n.kind && counts()[n.kind] !== undefined) { <span class="bm-cnt">{{ counts()[n.kind] }}</span> }
                </button>
              }
            }
          </div>
        }
      </aside>

      <!-- ── list ───────────────────────────────────────────────────── -->
      <section class="bm-result">
        @if (page() === 'overview') {
          <header class="bm-result-head">
            <div><h2>Overview</h2>
              <div class="bm-dim bm-small">inventory observed {{ inventoryAge() || '—' }}@if (stale()) { · <span class="bm-err">stale</span> }</div></div>
            <div class="bm-head-actions"><button mat-stroked-button (click)="loadInventory(true)" [disabled]="busy()" [attr.title]="busy() ? 'Working…' : null"><mat-icon>refresh</mat-icon> Refresh now</button></div>
          </header>
          @if (inventory(); as inv) {
            <div class="bm-tiles">
              <div class="bm-tile"><div class="bm-tile-n">{{ inv.nodes.length }}</div><div>node(s)</div>
                <div class="bm-small bm-dim">{{ nodesReady(inv) }} ready</div></div>
              <div class="bm-tile"><div class="bm-tile-n">{{ inv.namespaces.length }}</div><div>namespace(s)</div></div>
              @for (t of totals(inv); track t[0]) {
                <div class="bm-tile"><div class="bm-tile-n">{{ t[1] }}</div><div>{{ t[0] }}(s)</div></div>
              }
              <div class="bm-tile" [class.bm-tile--bad]="unhealthy(inv) > 0"><div class="bm-tile-n">{{ unhealthy(inv) }}</div><div>unhealthy workload(s)</div></div>
            </div>
            <h3>Nodes</h3>
            <table class="bm-table">
              <thead><tr><th>Name</th><th>State</th><th>Roles</th><th>Version</th><th>IP</th><th>CPU</th><th>Memory</th><th>Taints</th></tr></thead>
              <tbody>
                @for (n of inv.nodes; track n.name) {
                  <tr>
                    <td>{{ n.name }}</td><td><span class="bm-pill bm-pill--{{ badge(n.state) }}" [title]="n.state.detail">{{ label(n.state) }}</span></td>
                    <td>{{ n.roles.join(', ') }}</td><td class="bm-mono">{{ n.kubelet_version }}</td><td class="bm-mono">{{ n.internal_ip }}</td>
                    <td class="bm-num">{{ n.allocatable['cpu'] }}</td><td class="bm-num">{{ n.allocatable['memory'] }}</td>
                    <td class="bm-dim">{{ n.taints.join(', ') || '—' }}</td>
                  </tr>
                }
              </tbody>
            </table>
            <h3>Namespaces</h3>
            <table class="bm-table">
              <thead><tr><th>Name</th><th>State</th><th>Workloads</th><th>Unhealthy</th><th>Pod security</th></tr></thead>
              <tbody>
                @for (ns of inv.namespaces; track ns.name) {
                  <tr class="bm-click" (click)="setNamespace(ns.name)">
                    <td>{{ ns.name }}@if (ns.system) { <span class="bm-dim bm-small"> system</span> }</td>
                    <td><span class="bm-pill bm-pill--{{ badge(ns.state) }}">{{ label(ns.state) }}</span></td>
                    <td class="bm-dim">{{ nsCounts(inv, ns.name) }}</td>
                    <td class="bm-num" [class.bm-err]="(inv.workloads.by_namespace[ns.name]?.unhealthy || 0) > 0">{{ inv.workloads.by_namespace[ns.name]?.unhealthy || 0 }}</td>
                    <td class="bm-mono bm-small">{{ pss(ns.pod_security) }}</td>
                  </tr>
                }
              </tbody>
            </table>
            <h3>Recent warnings <span class="bm-dim bm-small">events of type Warning — short-lived on the cluster</span></h3>
            @if (inv.recent_warnings.length) {
              <table class="bm-table">
                <thead><tr><th>Namespace</th><th>Object</th><th>Reason</th><th>Message</th><th>Count</th></tr></thead>
                <tbody>
                  @for (w of inv.recent_warnings; track $index) {
                    <tr><td>{{ w.namespace }}</td><td class="bm-mono">{{ w.object }}</td><td>{{ w.reason }}</td><td class="bm-wrap">{{ w.message }}</td><td class="bm-num">{{ w.count ?? '' }}</td></tr>
                  }
                </tbody>
              </table>
            } @else { <p class="bm-dim">No Warning events retained right now.</p> }
          } @else if (!busy()) {
            <div class="bm-note bm-note--err">No inventory: {{ error() || 'the cluster has not been read yet' }}</div>
          }
        } @else if (page() === 'helm') {
          <header class="bm-result-head"><div><h2>Helm releases</h2>
            <div class="bm-dim bm-small">Charts are deployed and rolled back on the access host's Kubernetes tab — one place for Helm.</div></div></header>
          <p><a mat-flat-button [routerLink]="['/hosts', cluster()?.agent_id]" [queryParams]="{ tab: 'Management' }"><mat-icon>hub</mat-icon> Open Helm on {{ cluster()?.agent_name }}</a></p>
        } @else if (page() === 'apps') {
          <header class="bm-result-head"><div><h2>Applications</h2>
            <div class="bm-dim bm-small">Workloads grouped by the recommended label <code>app.kubernetes.io/instance</code> (or name). Creating one by form arrives with the next block.</div></div>
            <div class="bm-head-actions">
              <a mat-flat-button [routerLink]="['/kubernetes', clusterId(), 'apps', 'new']" [queryParams]="{ namespace: namespace() || null }"><mat-icon>add</mat-icon> Create application</a>
              <button mat-stroked-button (click)="loadApps()" [disabled]="busy()" [attr.title]="busy() ? 'Working…' : null"><mat-icon>refresh</mat-icon> Refresh</button></div></header>
          @for (a of apps(); track a.name) {
            <div class="bm-app">
              <div class="bm-app-head"><strong>{{ a.name }}</strong> <span class="bm-dim bm-small">{{ a.namespace }}</span>
                <span class="bm-pill bm-pill--{{ badge(a.state) }}" [title]="a.state.detail">{{ label(a.state) }}</span>
                @if (editable(a)) { <a class="bm-edit" [routerLink]="['/kubernetes', clusterId(), 'apps', a.namespace, editable(a)]">Edit as form</a> }</div>
              <div class="bm-app-parts">
                @for (r of a.rows; track r.kind + r.name) {
                  <button class="bm-part" (click)="openRow(r)"><span class="bm-dim">{{ r.kind }}</span> {{ r.name }}
                    <span class="bm-pill bm-pill--{{ badge(r.state) }}">{{ label(r.state) }}</span></button>
                }
              </div>
            </div>
          } @empty { @if (!busy()) { <p class="bm-dim">No workloads{{ namespace() ? ' in ' + namespace() : '' }}.</p> } }
        } @else if (page() === 'all') {
          <header class="bm-result-head"><div><h2>All object kinds</h2>
            <div class="bm-dim bm-small">{{ apiResources().length }} kinds the API server serves, including custom resources. Pick one to list it.</div></div></header>
          <div class="bm-table-wrap"><table class="bm-table">
            <thead><tr><th>Kind</th><th>Resource</th><th>API group</th><th>Scope</th><th>Short names</th></tr></thead>
            <tbody>
              @for (r of apiResources(); track r.name + r.api_version) {
                <tr class="bm-click" (click)="selectKind(r)"><td>{{ r.kind }}</td><td class="bm-mono">{{ r.name }}</td><td class="bm-mono">{{ r.api_version }}</td>
                  <td>{{ r.namespaced ? 'namespaced' : 'cluster' }}</td><td class="bm-mono">{{ r.short_names.join(', ') }}</td></tr>
              }
            </tbody>
          </table></div>
        } @else if (kind()) {
          <header class="bm-result-head">
            <div><h2>{{ nodeTitle() }}</h2>
              <div class="bm-dim bm-small">{{ rows().length }} row(s){{ namespace() ? ' in ' + namespace() : ' across all namespaces' }}
                @if (listError()) { · <span class="bm-err">could not be read</span> }</div></div>
            <div class="bm-head-actions">
              <input class="bm-filter" placeholder="filter" [ngModel]="filter()" (ngModelChange)="filter.set($event)" />
              <button mat-stroked-button (click)="loadRows()" [disabled]="busy()" [attr.title]="busy() ? 'Working…' : null"><mat-icon>refresh</mat-icon> Refresh</button>
            </div>
          </header>
          @if (listError()) { <div class="bm-note bm-note--err">{{ listError() }}</div> }
          <div class="bm-table-wrap">
            <table class="bm-table">
              <thead><tr>
                <th>Name</th>@if (!namespace() && rowsNamespaced()) { <th>Namespace</th> }<th>State</th>
                @for (c of columns(); track c[0]) { <th>{{ c[1] }}</th> }<th>Age</th>
              </tr></thead>
              <tbody>
                @for (r of filtered(); track r.kind + (r.namespace || '') + r.name) {
                  <tr class="bm-click" [class.bm-sel]="isOpen(r)" (click)="openRow(r)">
                    <td>{{ r.name }}</td>
                    @if (!namespace() && rowsNamespaced()) { <td class="bm-dim">{{ r.namespace }}</td> }
                    <td><span class="bm-pill bm-pill--{{ badge(r.state) }}" [title]="(r.state.reason || '') + ' — ' + r.state.detail">{{ label(r.state) }}</span></td>
                    @for (c of columns(); track c[0]) { <td [class.bm-wrap]="c[0] === 'message'">{{ fmt(r.summary[c[0]]) }}</td> }
                    <td class="bm-dim">{{ age(r.age_seconds) }}</td>
                  </tr>
                } @empty {
                  <tr><td colspan="12" class="bm-dim">@if (busy()) { loading… } @else { nothing here }</td></tr>
                }
              </tbody>
            </table>
          </div>
        } @else {
          <div class="bm-empty"><mat-icon>hub</mat-icon><p>Pick a node in the list on the left.</p></div>
        }
      </section>

      <!-- ── inspector ──────────────────────────────────────────────── -->
      <aside class="bm-inspector" [class.bm-inspector--open]="!!detail()">
        @if (detailRow(); as r) {
          <div class="bm-ins-head">
            <div><span class="bm-dim bm-small">{{ r.kind }}@if (r.namespace) { · {{ r.namespace }} }</span><h3>{{ r.name }}</h3></div>
            <span class="bm-pill bm-pill--{{ badge(r.state) }}">{{ label(r.state) }}</span>
            <button mat-icon-button (click)="closeDetail()" aria-label="Close"><mat-icon>close</mat-icon></button>
          </div>
          @if (r.state.reason) {
            <div class="bm-why-box" [class.bm-why-box--bad]="badge(r.state) === 'bad'">
              <div><strong>{{ r.state.explain?.title || r.state.reason }}</strong> <span class="bm-dim bm-small bm-mono">{{ r.state.reason }}</span></div>
              @if (r.state.detail) { <div class="bm-small">{{ r.state.detail }}</div> }
              @if (r.state.explain?.explanation) { <div class="bm-small bm-expl">{{ r.state.explain?.explanation }}</div> }
              @if (r.state.explain?.fix) { <div class="bm-small"><strong>What to do:</strong> {{ r.state.explain?.fix }}</div> }
              @if (r.state.explain?.doc) { <a class="bm-small" [href]="r.state.explain?.doc" target="_blank" rel="noopener">kubernetes.io ↗</a> }
            </div>
          }
          <!-- ACTIONS: one row, each either enabled or greyed out WITH its reason (never a click that fails). -->
          @if (actions(); as ac) {
            <div class="bm-actionbar">
              @for (a of visibleActions(ac); track a.action) {
                <button mat-stroked-button [disabled]="busy()" [bmBlocked]="a.available ? '' : (a.reason || 'Not available for this resource')" bmBlockedMode="tip" [title]="a.reason" (click)="runAction(a)">
                  <mat-icon>{{ actionIcon(a.action) }}</mat-icon> {{ actionLabel(a.action) }}
                </button>
              }
              @if (editableAs(r)) { <a mat-stroked-button [routerLink]="['/kubernetes', clusterId(), 'apps', r.namespace, r.name]"><mat-icon>edit</mat-icon> Edit as form</a> }
              <button mat-stroked-button class="bm-danger" [disabled]="busy()" [attr.title]="busy() ? 'Working…' : null" (click)="deletePreview()"><mat-icon>delete</mat-icon> Delete…</button>
            </div>
            @if (scaleOpen()) {
              <div class="bm-inline">
                <label>Replicas <input type="number" min="0" [ngModel]="scaleTo()" (ngModelChange)="scaleTo.set($event)" /></label>
                <button mat-flat-button [disabled]="busy()" [attr.title]="busy() ? 'Working…' : null" (click)="doScale()">Scale</button>
                <button mat-button (click)="scaleOpen.set(false)">Cancel</button>
              </div>
            }
            @if (undoOpen()) {
              <div class="bm-inline">
                <label>Kubernetes revision
                  <select [ngModel]="undoTo()" (ngModelChange)="undoTo.set(+$event)">
                    <option [value]="0">previous</option>
                    @for (h of ac.rollout_history; track h.revision) { <option [value]="h.revision">{{ h.revision }}{{ h.change_cause ? ' — ' + h.change_cause : '' }}</option> }
                  </select></label>
                <button mat-flat-button [disabled]="busy()" [attr.title]="busy() ? 'Working…' : null" (click)="doUndo()">Roll back</button>
                <button mat-button (click)="undoOpen.set(false)">Cancel</button>
                <span class="bm-small bm-dim">Kubernetes' own revisions — Bossman's generations are on the Resource tab.</span>
              </div>
            }
            @if (deleteInfo(); as del) {
              <div class="bm-inline bm-inline--col">
                <strong>Delete {{ r.kind }} {{ r.name }}?</strong>
                @if (del.dependents.length) { <div class="bm-small">Goes with it: @for (d of del.dependents; track d.kind + d.name) { <span class="bm-mono">{{ d.kind }}/{{ d.name }}</span> } — {{ del.dependents[0].why }}</div> }
                @if (del.kept.length) { <div class="bm-small">Stays: @for (k of del.kept; track k.kind + k.name) { <span class="bm-mono">{{ k.kind }}/{{ k.name }}</span> } — {{ del.kept[0].why }}</div> }
                @if (!del.dependents.length && !del.kept.length) { <div class="bm-small">Nothing else depends on it.</div> }
                <div><button mat-flat-button class="bm-danger-flat" [disabled]="busy()" [attr.title]="busy() ? 'Working…' : null" (click)="doDelete()">Delete</button> <button mat-button (click)="deleteInfo.set(null)">Cancel</button></div>
              </div>
            }
            @if (actionMsg(); as m) { <div class="bm-note" [class.bm-note--err]="actionErr()">{{ m }}</div> }
          }
          <mat-tab-group>
            <mat-tab label="State"><ng-template matTabContent><div class="bm-tab">
              @if (detail(); as d) {
                <table class="bm-kv">
                  <tr><td>Stored as</td><td class="bm-mono">{{ d.etcd_key }}</td></tr>
                  <tr><td>resourceVersion</td><td class="bm-mono">{{ d.versions.resource_version }}</td></tr>
                  @if (d.versions.generation != null) {
                    <tr><td>generation</td><td class="bm-mono">{{ d.versions.generation }} desired / {{ d.versions.observed_generation ?? '—' }} observed
                      @if (d.versions.observed_generation != null && d.versions.observed_generation < d.versions.generation) { <span class="bm-err">(controller has not caught up)</span> }</td></tr>
                  }
                  <tr><td>Field managers</td><td class="bm-mono">{{ d.field_managers.join(', ') || '—' }}</td></tr>
                  <tr><td>Labels</td><td class="bm-mono bm-small">{{ labels(r.labels) }}</td></tr>
                </table>
                <p class="bm-small bm-dim">The key is where the API server keeps this object in etcd — shown to explain where the state lives. Bossman never reads or writes etcd; the API server is the only writer.</p>
                @if (conditions(d).length) {
                  <h4>Conditions <span class="bm-dim bm-small">status, as the controller reports it</span></h4>
                  <table class="bm-table bm-small">
                    <thead><tr><th>Type</th><th>Status</th><th>Reason</th><th>Message</th></tr></thead>
                    <tbody>@for (c of conditions(d); track c['type']) {
                      <tr><td>{{ c['type'] }}</td><td class="bm-mono">{{ c['status'] }}</td><td>{{ c['reason'] || '' }}</td><td class="bm-wrap">{{ c['message'] || '' }}</td></tr>
                    }</tbody>
                  </table>
                }
                <div class="bm-two">
                  <div><h4>Desired <span class="bm-dim bm-small">spec — what was asked</span></h4><pre class="bm-pre">{{ json(d.spec ?? dataOf(d)) }}</pre></div>
                  <div><h4>Observed <span class="bm-dim bm-small">status — what the controller reports</span></h4><pre class="bm-pre">{{ d.status ? json(d.status) : 'this kind carries no runtime status' }}</pre></div>
                </div>
              } @else { <p class="bm-dim">loading…</p> }
            </div></ng-template></mat-tab>
            @if (isWorkload(r)) {
              <mat-tab label="Pods"><ng-template matTabContent><div class="bm-tab">
                @if (selector()) {
                  <div class="bm-small bm-dim">selector <span class="bm-mono">{{ selector() }}</span></div>
                  <table class="bm-table bm-small">
                    <thead><tr><th>Pod</th><th>State</th><th>Ready</th><th>Restarts</th><th>Node</th><th>Age</th></tr></thead>
                    <tbody>
                      @for (p of pods(); track p.name) {
                        <tr class="bm-click" (click)="openRow(p)"><td>{{ p.name }}</td>
                          <td><span class="bm-pill bm-pill--{{ badge(p.state) }}" [title]="p.state.detail">{{ label(p.state) }}@if (p.state.reason && badge(p.state) !== 'good') { · {{ p.state.reason }} }</span></td>
                          <td>{{ p.summary['ready'] }}</td><td class="bm-num">{{ p.summary['restarts'] }}</td><td class="bm-dim">{{ p.summary['node'] }}</td><td class="bm-dim">{{ age(p.age_seconds) }}</td></tr>
                      } @empty { <tr><td colspan="6" class="bm-dim">no pods match the selector</td></tr> }
                    </tbody>
                  </table>
                } @else { <p class="bm-dim">This workload has no label selector.</p> }
              </div></ng-template></mat-tab>
            }
            <mat-tab label="Events"><ng-template matTabContent><div class="bm-tab">
              @if (events().length) {
                <table class="bm-table bm-small">
                  <thead><tr><th>Type</th><th>Reason</th><th>Object</th><th>Message</th><th>Last</th></tr></thead>
                  <tbody>@for (e of events(); track $index) {
                    <tr [class.bm-row-warn]="e.type === 'Warning'"><td>{{ e.type }}</td><td [title]="e.explain?.explanation || ''">{{ e.reason }}</td>
                      <td class="bm-mono">{{ e.object }}</td><td class="bm-wrap">{{ e.message }}</td><td class="bm-dim">{{ when(e.last_seen) }}</td></tr>
                  }</tbody>
                </table>
              } @else { <p class="bm-dim">No events retained for this object. Events are best-effort and short-lived on the cluster — an empty list means none are kept, not that nothing happened.</p> }
            </div></ng-template></mat-tab>
            @if (r.kind === 'Pod') {
              <mat-tab label="Logs"><ng-template matTabContent><div class="bm-tab">
                <div class="bm-logbar">
                  <select [ngModel]="logContainer()" (ngModelChange)="logContainer.set($event); loadLogs()" aria-label="Container">
                    @for (c of containers(); track c) { <option [value]="c">{{ c }}</option> }
                  </select>
                  <label class="bm-small"><input type="checkbox" [ngModel]="logPrevious()" (ngModelChange)="logPrevious.set($event); loadLogs()" /> previous (crashed) container</label>
                  <button mat-stroked-button (click)="loadLogs()" [disabled]="busy()" [attr.title]="busy() ? 'Working…' : null"><mat-icon>refresh</mat-icon></button>
                </div>
                @if (logs(); as l) {
                  @if (l.error) { <div class="bm-note bm-note--err">{{ l.error }}</div> }
                  <pre class="bm-pre bm-log">{{ l.lines.join('\n') || '(no output)' }}</pre>
                }
              </div></ng-template></mat-tab>
            }
            <mat-tab label="Resource"><ng-template matTabContent><div class="bm-tab">
              <p class="bm-small bm-dim">Values are one typed field per spec value. Preview is a server-side dry run plus a diff; Apply is a server-side apply recorded as a generation, filed as a change proposal unless YOLO mode is on.</p>
              @if (resourceRef(); as ref) { <app-resource-inspector [ref]="ref" /> }
            </div></ng-template></mat-tab>
            <mat-tab label="YAML"><ng-template matTabContent><div class="bm-tab">
              <p class="bm-small bm-dim">Edit the manifest, Preview runs a server-side dry run and diff, Apply is a server-side apply recorded as a generation (a proposal unless YOLO mode is on). Server-owned metadata (status, resourceVersion, managedFields) is dropped before applying.</p>
              <textarea class="bm-yaml-edit" [ngModel]="yamlDraft()" (ngModelChange)="yamlDraft.set($event); yamlDiff.set(null)"></textarea>
              <div class="bm-inline">
                <span class="bm-why"><button mat-stroked-button [bmBlocked]="yamlPreviewBlocked()" bmBlockedMode="tip" (click)="yamlPreview()"><mat-icon>difference</mat-icon> Preview</button></span>
                <span class="bm-why"><button mat-flat-button [bmBlocked]="yamlApplyBlocked()" (click)="yamlApply()"><mat-icon>play_arrow</mat-icon> Apply</button></span>
                <button mat-button (click)="resetYaml()">Reset</button>
              </div>
              @if (yamlError(); as e) { <div class="bm-note bm-note--err">{{ e }}</div> }
              @if (yamlDiff(); as d) {
                <div class="bm-small">Server verdict: <strong>{{ d.action }}</strong>@if (yamlRefused()) { — {{ yamlRefusedReason() }} }</div>
                @if (d.action === 'update' && yamlDiffText()) { <pre class="bm-pre bm-diff">{{ yamlDiffText() }}</pre> }
              }
            </div></ng-template></mat-tab>
          </mat-tab-group>
        }
      </aside>
    </div>
  `,
  styles: [`
    .bm-k8s { display: grid; grid-template-columns: 250px 1fr; gap: 0; height: calc(100vh - 120px); min-height: 520px; position: relative; }
    .bm-scope { border-right: 1px solid var(--mat-sys-outline-variant); overflow-y: auto; padding: 10px 8px 24px; }
    .bm-scope-head { display: flex; gap: 10px; align-items: center; padding: 6px 8px 10px; }
    .bm-scope-title { font-weight: 600; }
    .bm-small { font-size: 12px; } .bm-dim { opacity: 0.62; } .bm-mono { font-family: ui-monospace, monospace; }
    .bm-err { color: var(--bm-red, #c62828); }
    .bm-note { margin: 8px; padding: 8px 10px; border-radius: 6px; font-size: 12px; line-height: 1.45; background: color-mix(in srgb, var(--mat-sys-on-surface) 7%, transparent); }
    .bm-note--why { background: color-mix(in srgb, var(--bm-gold, #ffc800) 18%, transparent); }
    .bm-note--err { background: color-mix(in srgb, var(--bm-red, #c62828) 12%, transparent); margin: 0 0 12px; }
    .bm-nsrow { display: flex; flex-direction: column; gap: 3px; padding: 4px 8px 10px; }
    .bm-nsrow select { padding: 6px 8px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font: inherit; font-size: 13px; }
    .bm-group { margin-bottom: 2px; }
    .bm-group-head { display: flex; align-items: center; gap: 4px; padding: 5px 6px; cursor: pointer; border-radius: 6px; }
    .bm-group-head:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-chev, .bm-gicon { font-size: 18px; width: 18px; height: 18px; } .bm-gname { font-size: 13px; }
    .bm-node { display: flex; align-items: center; gap: 8px; width: calc(100% - 22px); margin-left: 22px; padding: 5px 8px; border: 0; border-radius: 6px; background: transparent; color: inherit; font: inherit; font-size: 13px; text-align: left; cursor: pointer; }
    .bm-node:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 7%, transparent); }
    .bm-node mat-icon { font-size: 17px; width: 17px; height: 17px; }
    .bm-node.bm-sel { background: color-mix(in srgb, var(--mat-sys-primary) 18%, transparent); font-weight: 600; }
    .bm-cnt { margin-left: auto; font-size: 11px; opacity: 0.6; font-variant-numeric: tabular-nums; }
    .bm-result { padding: 14px 18px 0; overflow: auto; display: flex; flex-direction: column; min-width: 0; }
    .bm-result-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; }
    .bm-result-head h2 { margin: 0 0 2px; font-size: 18px; } .bm-result h3 { font-size: 14px; margin: 18px 0 6px; } h4 { font-size: 12.5px; margin: 12px 0 4px; }
    .bm-head-actions { display: flex; gap: 8px; align-items: center; }
    .bm-filter { padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font: inherit; font-size: 13px; min-width: 160px; }
    .bm-empty { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 6px; height: 100%; text-align: center; }
    .bm-empty mat-icon { font-size: 46px; width: 46px; height: 46px; opacity: 0.35; }
    .bm-tiles { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 12px; }
    .bm-tile { min-width: 120px; padding: 10px 14px; border-radius: 10px; border: 1px solid var(--mat-sys-outline-variant); font-size: 12.5px; }
    .bm-tile-n { font-size: 24px; font-weight: 600; color: var(--bm-green); } .bm-tile--bad .bm-tile-n { color: var(--bm-red); }
    .bm-table-wrap { flex: 1; overflow: auto; margin-top: 12px; }
    .bm-table { width: 100%; border-collapse: collapse; font-size: var(--bm-font-table); }
    .bm-table th { position: sticky; top: 0; z-index: 1; text-align: left; padding: var(--bm-cell-py) var(--bm-cell-px); font-size: 11px; text-transform: uppercase; opacity: 0.65; background: var(--mat-sys-surface); border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-table td { padding: var(--bm-cell-py) var(--bm-cell-px); border-bottom: 1px solid var(--mat-sys-outline-variant); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 380px; }
    .bm-table td.bm-wrap { white-space: normal; max-width: 520px; }
    .bm-table tbody tr.bm-click { cursor: pointer; } .bm-table tbody tr.bm-click:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
    .bm-table tbody tr.bm-sel { background: color-mix(in srgb, var(--mat-sys-primary) 14%, transparent); }
    .bm-table tbody tr.bm-row-warn td { background: color-mix(in srgb, var(--bm-gold, #ffc800) 8%, transparent); }
    .bm-num { text-align: right; font-variant-numeric: tabular-nums; }
    .bm-pill { font-size: 11px; padding: 1px 8px; border-radius: 9px; white-space: nowrap; background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
    .bm-pill--good { background: color-mix(in srgb, var(--bm-green, #2e7d32) 24%, transparent); }
    .bm-pill--warn { background: color-mix(in srgb, var(--bm-gold, #ffc800) 30%, transparent); }
    .bm-pill--bad { background: color-mix(in srgb, var(--bm-red, #c62828) 26%, transparent); }
    .bm-app { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 10px 12px; margin-top: 10px; }
    .bm-app-head { display: flex; align-items: center; gap: 8px; }
    .bm-edit { margin-left: auto; font-size: 12.5px; }
    .bm-app-parts { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
    .bm-part { display: inline-flex; align-items: center; gap: 6px; font: inherit; font-size: 12.5px; padding: 4px 10px; border-radius: 999px; border: 1px solid var(--mat-sys-outline-variant); background: transparent; color: inherit; cursor: pointer; }
    /* z-index: the list's sticky table header (z-index 1) painted over the drawer; the drawer is the top layer of the page. */
    .bm-inspector { position: absolute; top: 0; right: 0; bottom: 0; z-index: 5; width: min(560px, 60%); transform: translateX(105%); transition: transform .18s ease; background: var(--mat-sys-surface); border-left: 1px solid var(--mat-sys-outline-variant); overflow-y: auto; padding: 12px 14px; box-shadow: -8px 0 24px rgba(0,0,0,.25); }
    .bm-inspector--open { transform: none; }
    .bm-ins-head { display: flex; align-items: center; gap: 10px; } .bm-ins-head h3 { margin: 0; font-size: 16px; font-family: ui-monospace, monospace; } .bm-ins-head > div { flex: 1; }
    .bm-why-box { margin: 8px 0; padding: 8px 10px; border-radius: 8px; background: color-mix(in srgb, var(--bm-gold, #ffc800) 14%, transparent); display: flex; flex-direction: column; gap: 3px; }
    .bm-why-box--bad { background: color-mix(in srgb, var(--bm-red, #c62828) 12%, transparent); }
    .bm-expl { opacity: 0.85; }
    .bm-tab { padding: 10px 2px; }
    .bm-actionbar { display: flex; flex-wrap: wrap; gap: 6px; margin: 6px 0 8px; }
    .bm-actionbar button, .bm-actionbar a { font-size: 12.5px; }
    .bm-inline { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin: 4px 0 8px; padding: 8px 10px; border-radius: 8px; background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
    .bm-inline--col { flex-direction: column; align-items: flex-start; gap: 4px; }
    .bm-inline label { display: flex; align-items: center; gap: 6px; font-size: 12.5px; }
    .bm-inline input, .bm-inline select { padding: 5px 8px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font: inherit; width: 90px; }
    .bm-inline select { width: auto; }
    .bm-danger { color: var(--mat-sys-error); } .bm-danger-flat { background: var(--mat-sys-error) !important; color: #fff !important; }
    .bm-yaml-edit { width: 100%; min-height: 320px; font-family: ui-monospace, monospace; font-size: 11.5px; padding: 8px; border-radius: 8px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface-variant); color: inherit; resize: vertical; }
    .bm-diff { max-height: 260px; }
    .bm-kv { border-collapse: collapse; font-size: 12.5px; } .bm-kv td { padding: 3px 12px 3px 0; vertical-align: top; } .bm-kv td:first-child { opacity: 0.6; white-space: nowrap; }
    .bm-two { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; } @media (max-width: 1100px) { .bm-two { grid-template-columns: 1fr; } }
    .bm-pre { font-size: 11.5px; background: var(--mat-sys-surface-variant); padding: 10px; border-radius: 8px; max-height: 320px; overflow: auto; margin: 0; white-space: pre-wrap; word-break: break-word; }
    .bm-yaml { max-height: 70vh; } .bm-log { max-height: 60vh; white-space: pre; }
    .bm-logbar { display: flex; gap: 10px; align-items: center; margin-bottom: 8px; }
    .bm-logbar select { padding: 5px 8px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font: inherit; }
  `],
})
export class KubernetesExplorerComponent implements OnInit {
  private route = inject(ActivatedRoute);
  private svc = inject(KubernetesService);
  private resources = inject(ResourceService);
  private snack = inject(MatSnackBar);

  // ---- actions + YAML editing (Block 6) ----
  actions = signal<ActionsResponse | null>(null);
  scaleOpen = signal(false); scaleTo = signal(1);
  undoOpen = signal(false); undoTo = signal(0);
  deleteInfo = signal<K8sDeleteResult | null>(null);
  actionMsg = signal(''); actionErr = signal(false);
  yamlDraft = signal(''); yamlDiff = signal<ResourceDiff | null>(null); yamlError = signal('');

  tree = TREE;
  clusterId = signal('');
  cluster = signal<KubernetesCluster | null>(null);
  inventory = signal<Inventory | null>(null);
  stale = signal(false);
  observedAt = signal<string | null>(null);
  apiResources = signal<ApiResource[]>([]);
  namespace = signal('');
  open = signal(new Set<string>(['cluster', 'workloads', 'apps']));
  nodeId = signal('overview');
  page = signal<TreeNode['page'] | null>('overview');
  kind = signal<string | null>(null);
  nodeTitle = signal('');
  rows = signal<ObjectRow[]>([]);
  listError = signal('');
  filter = signal('');
  busy = signal(false);
  error = signal('');
  apps = signal<{ name: string; namespace: string | null; state: StateInfo; rows: ObjectRow[] }[]>([]);

  detailRow = signal<ObjectRow | null>(null);
  detail = signal<ObjectDetail | null>(null);
  pods = signal<ObjectRow[]>([]);
  events = signal<K8sEvent[]>([]);
  logs = signal<LogsResponse | null>(null);
  logContainer = signal('');
  logPrevious = signal(false);

  namespaces = computed(() => (this.inventory()?.namespaces ?? []).slice().sort((a, b) => a.name.localeCompare(b.name)));
  counts = computed(() => {
    const inv = this.inventory(); const out: Record<string, number> = {};
    if (!inv) return out;
    const ns = this.namespace();
    const src = ns ? (inv.workloads.by_namespace[ns]?.counts ?? {}) : inv.workloads.totals;
    const map: Record<string, string> = { Deployment: 'deployments', StatefulSet: 'statefulsets', DaemonSet: 'daemonsets', Job: 'jobs', CronJob: 'cronjobs', Pod: 'pods' };
    for (const [k, v] of Object.entries(src)) if (map[k]) out[map[k]] = v;
    if (!ns) { out['nodes'] = inv.nodes.length; out['namespaces'] = inv.namespaces.length; }
    return out;
  });
  filtered = computed(() => {
    const f = this.filter().trim().toLowerCase();
    return f ? this.rows().filter((r) => JSON.stringify([r.name, r.namespace, r.summary, r.state.reason]).toLowerCase().includes(f)) : this.rows();
  });
  columns = computed(() => { const k = this.rows()[0]?.kind; return (k && COLUMNS[k]) || [] as [string, string][]; });
  rowsNamespaced = computed(() => this.rows().some((r) => !!r.namespace));
  inventoryAge = computed(() => { const t = this.observedAt(); return t ? `${formatDuration((Date.now() - new Date(t).getTime()) / 1000)} ago` : ''; });
  selector = computed(() => {
    const d = this.detail(); if (!d) return '';
    const sel = (d.spec?.['selector'] as { matchLabels?: Record<string, string> } | undefined);
    const ml = sel?.matchLabels; if (!ml) return '';
    return Object.entries(ml).sort().map(([k, v]) => `${k}=${v}`).join(',');
  });
  containers = computed(() => {
    const d = this.detail(); const spec = d?.spec as { containers?: { name: string }[]; initContainers?: { name: string }[] } | null;
    return [...(spec?.initContainers ?? []), ...(spec?.containers ?? [])].map((c) => c.name);
  });
  /** The Resource ref for the generic inspector — the four verbs for this object. */
  resourceRef = computed<ResourceRef | null>(() => {
    const c = this.cluster(); const r = this.detailRow(); if (!c || !r) return null;
    return { agentId: c.agent_id, kind: 'k8s', name: r.name, namespace: r.namespace || undefined, cluster: c.id, apiVersion: r.api_version, objectKind: r.kind };
  });

  ngOnInit(): void {
    this.route.paramMap.subscribe((pm) => {
      const id = pm.get('id') || '';
      this.clusterId.set(id);
      this.svc.get(id).subscribe({ next: (c) => this.cluster.set(c), error: (e) => this.error.set(this.msg(e)) });
      this.loadInventory(false);
    });
  }

  loadInventory(refresh: boolean): void {
    this.busy.set(true);
    this.svc.inventory(this.clusterId(), refresh).subscribe({
      next: (r) => {
        this.inventory.set(r.inventory); this.stale.set(r.stale); this.observedAt.set(r.observed_at);
        this.apiResources.set(r.inventory?.api_resources ?? []); this.busy.set(false);
        if (refresh) this.svc.get(this.clusterId()).subscribe((c) => this.cluster.set(c));
      },
      error: (e) => { this.busy.set(false); this.error.set(this.msg(e)); },
    });
  }

  toggle(id: string): void { this.open.update((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; }); }
  setNamespace(ns: string): void {
    this.namespace.set(ns);
    if (this.kind()) this.loadRows();
    if (this.page() === 'apps') this.loadApps();
  }
  selectNode(n: TreeNode): void {
    this.nodeId.set(n.id); this.nodeTitle.set(n.title); this.closeDetail();
    if (n.page) { this.page.set(n.page); this.kind.set(null); if (n.page === 'apps') this.loadApps(); if (n.page === 'all' && !this.apiResources().length) this.svc.apiResources(this.clusterId()).subscribe((r) => this.apiResources.set(r.resources)); return; }
    this.page.set(null); this.kind.set(n.kind || null); this.loadRows();
  }
  selectKind(r: ApiResource): void {
    this.nodeId.set('all:' + r.name); this.nodeTitle.set(r.kind); this.page.set(null); this.kind.set(r.name); this.closeDetail(); this.loadRows();
  }

  loadRows(): void {
    const k = this.kind(); if (!k) return;
    this.busy.set(true); this.listError.set(''); this.rows.set([]);
    const namespaced = this.apiResources().find((r) => r.name === k || r.kind.toLowerCase() === k.toLowerCase())?.namespaced ?? true;
    this.svc.objects(this.clusterId(), k, namespaced ? (this.namespace() || null) : null).subscribe({
      next: (l) => { this.rows.set(l.items); this.busy.set(false); if (l.warnings) this.snack.open(l.warnings, 'OK', { duration: 6000 }); },
      error: (e) => { this.busy.set(false); this.listError.set(this.msg(e)); },
    });
  }

  /** Portainer's "Applications": workloads grouped by app.kubernetes.io/instance (then /name, then the name). */
  loadApps(): void {
    this.busy.set(true);
    const ns = this.namespace() || null;
    this.svc.objects(this.clusterId(), 'deployments,statefulsets,daemonsets,cronjobs', ns).subscribe({
      next: (l) => {
        const groups = new Map<string, ObjectRow[]>();
        for (const r of l.items) {
          const key = `${r.namespace}/${r.labels['app.kubernetes.io/instance'] || r.labels['app.kubernetes.io/name'] || r.labels['app'] || r.name}`;
          groups.set(key, [...(groups.get(key) ?? []), r]);
        }
        const rank: Record<string, number> = { failed: 0, degraded: 1, pending: 2, progressing: 3, unknown: 4, terminating: 5, suspended: 6, healthy: 7, completed: 8, static: 9 };
        this.apps.set([...groups.entries()].map(([key, rows]) => {
          const worst = rows.map((r) => r.state).sort((a, b) => rank[a.state] - rank[b.state])[0];
          return { name: key.split('/').slice(1).join('/'), namespace: rows[0].namespace, state: worst, rows };
        }).sort((a, b) => rank[a.state.state] - rank[b.state.state] || a.name.localeCompare(b.name)));
        this.busy.set(false);
      },
      error: (e) => { this.busy.set(false); this.listError.set(this.msg(e)); },
    });
  }

  isOpen(r: ObjectRow): boolean { const d = this.detailRow(); return !!d && d.kind === r.kind && d.name === r.name && d.namespace === r.namespace; }
  /** The requests of the object currently open. RACE-FREE BY CANCELLATION: opening another object cancels them,
   * so a slow answer for the PREVIOUS object (its manifest, pods, events) can never land in the inspector of the
   * new one — measured, the YAML tab showed the previously opened Pod's manifest under a Deployment, and Preview
   * then answered "manifest does not describe this object". */
  private openSubs: Subscription[] = [];
  private cancelOpen(): void { this.openSubs.forEach((s) => s.unsubscribe()); this.openSubs = []; }
  openRow(r: ObjectRow): void {
    this.cancelOpen();
    // Another object: its action state (open dialogs, the last result) does not carry over. The SAME object
    // re-read after a write (reopen) keeps the result message it just produced.
    if (!this.isOpen(r)) this.resetActionUi();
    this.detailRow.set(r); this.detail.set(null); this.pods.set([]); this.events.set([]); this.logs.set(null); this.actions.set(null);
    // The draft belongs to the object: emptied NOW, refilled when THIS object's manifest arrives.
    this.yamlDraft.set('');
    const kindArg = r.api_version && r.api_version.includes('/') ? `${r.kind}.${r.api_version.split('/')[1]}.${r.api_version.split('/')[0]}` : r.kind;
    this.openSubs.push(this.svc.object(this.clusterId(), kindArg, r.name, r.namespace).subscribe({
      next: (d) => {
        this.detail.set(d);
        this.resetYaml();
        this.loadActions(r);
        if (this.isWorkload(r) && this.selector() && r.namespace) this.openSubs.push(this.svc.pods(this.clusterId(), r.namespace, this.selector()).subscribe((p) => this.pods.set(p.items)));
        if (r.kind === 'Pod') { this.logContainer.set(this.containers()[this.containers().length - 1] || ''); this.loadLogs(); }
      },
      error: (e) => this.snack.open(this.msg(e), 'OK', { duration: 8000 }),
    }));
    this.openSubs.push(this.svc.events(this.clusterId(), { namespace: r.namespace, name: r.name, kind: r.kind }).subscribe({ next: (e) => this.events.set(e.events), error: () => this.events.set([]) }));
  }
  closeDetail(): void { this.cancelOpen(); this.detailRow.set(null); this.detail.set(null); this.actions.set(null); this.resetActionUi(); }
  private resetActionUi(): void { this.scaleOpen.set(false); this.undoOpen.set(false); this.deleteInfo.set(null); this.actionMsg.set(''); this.yamlDiff.set(null); this.yamlError.set(''); }
  private loadActions(r: ObjectRow): void {
    this.openSubs.push(this.svc.actions(this.clusterId(), r.kind, r.name, r.namespace).subscribe({ next: (a) => this.actions.set(a), error: () => this.actions.set(null) }));
  }
  private kindArgOf(r: ObjectRow): string {
    return r.api_version && r.api_version.includes('/') ? `${r.kind}.${r.api_version.split('/')[1]}.${r.api_version.split('/')[0]}` : r.kind;
  }
  /** Actions that exist for this KIND; the ones the current state forbids stay visible, greyed out with the reason. */
  visibleActions(ac: ActionsResponse): ActionInfo[] { return ac.actions.filter((a) => a.applies); }
  editableAs(r: ObjectRow): boolean { return !!r.namespace && ['Deployment', 'StatefulSet', 'DaemonSet', 'CronJob', 'Job'].includes(r.kind); }
  actionLabel(a: string): string {
    return { restart: 'Restart', undo: 'Roll back (revision)', scale: 'Scale…', pause: 'Pause rollout', resume: 'Resume rollout', cordon: 'Cordon', uncordon: 'Uncordon',
             drain: 'Drain', delete_pod: 'Delete pod', suspend_job: 'Suspend', resume_job: 'Resume' }[a] ?? a;
  }
  actionIcon(a: string): string {
    return { restart: 'restart_alt', undo: 'history', scale: 'unfold_more', pause: 'pause', resume: 'play_arrow', cordon: 'block', uncordon: 'check_circle',
             drain: 'logout', delete_pod: 'delete', suspend_job: 'pause', resume_job: 'play_arrow' }[a] ?? 'bolt';
  }
  runAction(a: ActionInfo): void {
    const r = this.detailRow(); if (!r) return;
    this.actionMsg.set(''); this.actionErr.set(false);
    if (a.action === 'scale') { this.scaleTo.set(a.current ?? 1); this.scaleOpen.set(true); this.undoOpen.set(false); return; }
    if (a.action === 'undo') { this.undoTo.set(0); this.undoOpen.set(true); this.scaleOpen.set(false); return; }
    if (a.action === 'drain') {
      const ref = this.snack.open(`Drain ${r.name}? Every pod is evicted (honouring disruption budgets); the node stays cordoned.`, 'Drain', { duration: 10000 });
      ref.onAction().subscribe(() => this.send({ action: 'drain', kind: r.kind, name: r.name, namespace: r.namespace }));
      return;
    }
    this.send({ action: a.action, kind: r.kind, name: r.name, namespace: r.namespace });
  }
  doScale(): void { const r = this.detailRow(); if (r) this.send({ action: 'scale', kind: r.kind, name: r.name, namespace: r.namespace, replicas: Number(this.scaleTo()) }); }
  doUndo(): void { const r = this.detailRow(); if (r) this.send({ action: 'undo', kind: r.kind, name: r.name, namespace: r.namespace, revision: this.undoTo() || null }); }
  private send(body: { action: string; kind: string; name: string; namespace: string | null; replicas?: number; revision?: number | null }): void {
    this.busy.set(true);
    this.svc.runAction(this.clusterId(), body).subscribe({
      next: (res) => {
        this.busy.set(false); this.scaleOpen.set(false); this.undoOpen.set(false);
        if (res.awaiting_approval) { this.actionMsg.set(`Filed for approval (YOLO mode is off): proposal ${res.proposal_id}. Nothing changed yet.`); }
        else if (res.ok === false) { this.actionErr.set(true); this.actionMsg.set(res.error || res.stderr || `${body.action} failed`); }
        else { this.actionMsg.set(`${this.actionLabel(body.action)}: done${res.generation ? ' (generation ' + res.generation + ')' : ''}${res.stdout ? ' — ' + res.stdout.split('\n')[0] : ''}`); }
        this.reopen();
      },
      error: (e) => { this.busy.set(false); this.actionErr.set(true); this.actionMsg.set(this.msg(e)); },
    });
  }
  /** After a write: re-read the row's object, actions, pods and events (the list too, so the pill follows). */
  private reopen(): void {
    const r = this.detailRow(); if (!r) return;
    const keep = r;
    this.openRow(keep);
    if (this.kind()) this.loadRows();
  }
  deletePreview(): void {
    const ref = this.resourceRef(); if (!ref) return;
    this.busy.set(true);
    this.resources.deleteObject(ref, true).subscribe({
      next: (d) => { this.busy.set(false); this.deleteInfo.set(d); if (!d.ok) { this.actionErr.set(true); this.actionMsg.set(d.error || 'preview failed'); } },
      error: (e) => { this.busy.set(false); this.actionErr.set(true); this.actionMsg.set(this.msg(e)); },
    });
  }
  doDelete(): void {
    const ref = this.resourceRef(); const r = this.detailRow(); if (!ref || !r) return;
    this.busy.set(true);
    this.resources.deleteObject(ref, false).subscribe({
      next: (d) => {
        this.busy.set(false); this.deleteInfo.set(null);
        if (d.ok && d.awaiting_approval) { this.actionErr.set(false); this.actionMsg.set(`Filed for approval (YOLO mode is off): proposal ${d.proposal_id}. Nothing deleted yet.`); }
        else if (d.ok) { this.snack.open(`Deleted ${r.kind} ${r.name} — recorded as generation ${d.generation}; it shows as vanished in its history.`, 'OK', { duration: 7000 }); this.closeDetail(); if (this.kind()) this.loadRows(); if (this.page() === 'apps') this.loadApps(); }
        else { this.actionErr.set(true); this.actionMsg.set(d.error || 'delete failed'); }
      },
      error: (e) => { this.busy.set(false); this.actionErr.set(true); this.actionMsg.set(this.msg(e)); },
    });
  }
  // ---- YAML tab ----
  resetYaml(): void { const d = this.detail(); this.yamlDraft.set(d ? this.json(this.cleanManifest(d.object)) : ''); this.yamlDiff.set(null); this.yamlError.set(''); }
  private cleanManifest(o: Record<string, unknown>): Record<string, unknown> {
    const md = { ...(o['metadata'] as Record<string, unknown> || {}) };
    for (const k of ['managedFields', 'resourceVersion', 'uid', 'creationTimestamp', 'generation']) delete md[k];
    const out: Record<string, unknown> = { ...o, metadata: md }; delete out['status']; return out;
  }
  private parseYaml(): Record<string, unknown> | null {
    try { const v = JSON.parse(this.yamlDraft()); if (v && typeof v === 'object') return v as Record<string, unknown>; } catch { /* not JSON */ }
    this.yamlError.set('The manifest must be valid JSON (the editor shows the object as JSON).'); return null;
  }
  /** Why the YAML tab's Preview cannot run, or '' when it can. */
  yamlPreviewBlocked(): string {
    if (this.busy()) return 'Working…';
    if (!this.detail()) return 'The object is still loading';
    return '';
  }
  /** Why the YAML tab's Apply cannot run, or '' when it can — one reason, the first that applies. */
  yamlApplyBlocked(): string {
    if (this.busy()) return 'Working…';
    const d = this.yamlDiff();
    if (!d) return 'Preview first: Apply sends exactly what the server dry run has checked';
    if (this.yamlRefused()) return `The API server refused the manifest: ${this.yamlRefusedReason()}`;
    if (d.action === 'noop') return 'Nothing to apply: the server says the manifest matches the object as it is';
    return '';
  }
  yamlRefused(): boolean { return !!(this.yamlDiff() as unknown as { refused?: boolean } | null)?.refused; }
  yamlRefusedReason(): string { return (this.yamlDiff() as unknown as { reason?: string } | null)?.reason || ''; }
  yamlDiffText(): string { return (this.yamlDiff() as unknown as { diff_text?: string } | null)?.diff_text || ''; }
  yamlPreview(): void {
    const ref = this.resourceRef(); const m = this.parseYaml(); if (!ref || !m) return;
    this.busy.set(true); this.yamlError.set('');
    this.resources.plan(ref, { manifest: m }).subscribe({
      next: (d) => { this.busy.set(false); this.yamlDiff.set(d); },
      error: (e) => { this.busy.set(false); this.yamlError.set(this.msg(e)); },
    });
  }
  yamlApply(): void {
    const ref = this.resourceRef(); const m = this.parseYaml(); if (!ref || !m) return;
    this.busy.set(true);
    this.resources.apply(ref, { manifest: m }, false, 'edited as YAML').subscribe({
      next: (res) => {
        this.busy.set(false);
        if (res.awaiting_approval) this.snack.open(`Filed for approval: proposal ${res.proposal_id}.`, 'OK', { duration: 7000 });
        else if (res.ok === false) this.yamlError.set(res.error || 'apply failed');
        else { this.snack.open(`Applied — generation ${res.generation}.`, 'OK', { duration: 5000 }); this.yamlDiff.set(null); this.reopen(); }
      },
      error: (e) => { this.busy.set(false); this.yamlError.set(this.msg(e)); },
    });
  }
  loadLogs(): void {
    const r = this.detailRow(); if (!r || r.kind !== 'Pod' || !r.namespace) return;
    this.busy.set(true);
    this.svc.logs(this.clusterId(), r.namespace, r.name, this.logContainer() || null, 200, this.logPrevious()).subscribe({
      next: (l) => { this.logs.set(l); this.busy.set(false); },
      error: (e) => { this.busy.set(false); this.logs.set({ pod: r.name, container: this.logContainer(), previous: this.logPrevious(), lines: [], error: this.msg(e) }); },
    });
  }

  /** The workload the form can re-open (one Deployment/StatefulSet/DaemonSet/CronJob per application). */
  editable(a: { rows: ObjectRow[] }): string | null {
    const w = a.rows.find((r) => ['Deployment', 'StatefulSet', 'DaemonSet', 'CronJob', 'Job'].includes(r.kind));
    return w ? w.name : null;
  }

  // ---- rendering helpers ------------------------------------------------------------------
  isWorkload(r: ObjectRow): boolean { return WORKLOAD_KINDS.has(r.kind); }
  badge(s: StateInfo): string { return stateBadge(s.state); }
  label(s: StateInfo): string { return STATE_LABEL[s.state] ?? s.state; }
  age(sec: number | null): string { return sec == null ? '—' : formatDuration(sec); }
  when(ts: string | null): string { return ts ? `${formatDuration((Date.now() - new Date(ts).getTime()) / 1000)} ago` : '—'; }
  labels(l: Record<string, string>): string { return Object.entries(l).map(([k, v]) => `${k}=${v}`).join('  ') || '—'; }
  pss(p: Record<string, string>): string { return Object.entries(p).map(([k, v]) => `${k}=${v}`).join(' ') || '—'; }
  json(v: unknown): string { return JSON.stringify(v, null, 2); }
  dataOf(d: ObjectDetail): unknown { return d.object['data'] ?? d.object['rules'] ?? d.object['subjects'] ?? null; }
  conditions(d: ObjectDetail): Record<string, string>[] { return ((d.status?.['conditions'] as Record<string, string>[] | undefined) ?? []); }
  fmt(v: unknown): string {
    if (v == null || v === '') return '—';
    if (Array.isArray(v)) return v.length ? v.map((x) => (typeof x === 'object' ? JSON.stringify(x) : String(x))).join(', ') : '—';
    if (typeof v === 'object') return Object.entries(v as Record<string, unknown>).map(([k, x]) => `${k}=${x}`).join(' ') || '—';
    if (typeof v === 'boolean') return v ? 'yes' : 'no';
    return String(v);
  }
  nodesReady(inv: Inventory): number { return inv.nodes.filter((n) => n.ready === 'True').length; }
  totals(inv: Inventory): [string, number][] { return Object.entries(inv.workloads.totals).sort(); }
  unhealthy(inv: Inventory): number { return Object.values(inv.workloads.by_namespace).reduce((a, b) => a + (b.unhealthy || 0), 0); }
  nsCounts(inv: Inventory, ns: string): string { const c = inv.workloads.by_namespace[ns]?.counts; return c ? Object.entries(c).map(([k, v]) => `${v} ${k}`).join(', ') : '—'; }
  private msg(e: unknown): string {
    const err = e as { error?: { detail?: unknown }; message?: string };
    const d = err?.error?.detail;
    return typeof d === 'string' ? d : d && typeof d === 'object' ? JSON.stringify(d) : err?.message || 'request failed';
  }
}
