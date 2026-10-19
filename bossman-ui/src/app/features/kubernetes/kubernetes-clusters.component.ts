import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatCardModule } from '@angular/material/card';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatIconModule } from '@angular/material/icon';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatSnackBar } from '@angular/material/snack-bar';
import { Agent } from '../../core/models/agent.model';
import { AgentService } from '../../core/services/agent.service';
import { KubernetesCluster, KubernetesClusterInput, KubernetesService } from '../../core/services/kubernetes.service';
import { formatDuration } from '../../shared/format.util';
import { BlockedReasonDirective } from '../../shared/blocked-reason/blocked-reason.directive';

/**
 * Kubernetes clusters — the registry (project kubernetes-console, docs/kubernetes-console.md).
 *
 * A cluster is registered by naming its ACCESS HOST: the enrolled agent that holds kubectl and the
 * kubeconfig. Bossman never stores a cluster credential and never touches etcd. What this screen has to
 * make visible, because the model is causal:
 *  1. Reachability is a NAMED state with its reason (reachable | unreachable | never) — a cluster whose
 *     API server is down is listed as such, never as an empty explorer.
 *  2. The observed facts (version, nodes, namespaces) carry WHEN they were observed.
 *  3. The access host is the identity the cluster is reached through: change it and the facts reset.
 */
@Component({
  selector: 'app-kubernetes-clusters',
  standalone: true,
  imports: [BlockedReasonDirective, FormsModule, RouterLink, MatButtonModule, MatCardModule, MatFormFieldModule, MatIconModule, MatInputModule, MatSelectModule],
  template: `
    <div class="bm-page">
      <div class="bm-header-row">
        <h1>Kubernetes clusters</h1>
        <div class="bm-actions">
          <button mat-stroked-button (click)="reload()"><mat-icon>refresh</mat-icon> Refresh</button>
          <button mat-flat-button (click)="startNew()"><mat-icon>add</mat-icon> Register cluster</button>
        </div>
      </div>
      <p class="bm-subtitle">
        A cluster is reached through its <strong>access host</strong> — the enrolled host that has <code>kubectl</code>
        and a kubeconfig. Bossman keeps no cluster credential and never touches etcd: every read and write
        goes host → kubectl → API server.
      </p>

      <div class="bm-split">
        <mat-card class="bm-panel">
          <mat-card-content>
            <div class="bm-count"><span class="bm-big">{{ clusters().length }}</span> cluster(s)
              @if (loading()) { <span class="bm-dim">— loading…</span> }</div>
            @for (c of clusters(); track c.id) {
              <div class="bm-item" [class.bm-item-selected]="selectedId() === c.id" (click)="select(c)">
                <div class="bm-item-name">
                  <span class="bm-reach bm-reach--{{ c.reachability }}" [title]="c.unreachable_reason || c.reachability"></span>
                  {{ c.name }}
                </div>
                <div class="bm-item-meta">
                  {{ c.server_version || 'version unknown' }} · {{ c.node_count ?? '?' }} node(s) · {{ c.namespace_count ?? '?' }} namespace(s)
                  · via {{ c.agent_name || '?' }}
                </div>
              </div>
            } @empty {
              @if (!loading()) { <p class="bm-dim">No Kubernetes cluster registered yet. Register one by naming the host that can run <code>kubectl</code> against it.</p> }
            }
          </mat-card-content>
        </mat-card>

        <mat-card class="bm-panel">
          <mat-card-content>
            @if (draft(); as d) {
              <div class="bm-detail-head">
                <h2>{{ isNew() ? 'Register a Kubernetes cluster' : d.name }}</h2>
                @if (!isNew() && selected(); as c) {
                  <div class="bm-actions">
                    <a mat-flat-button [routerLink]="['/kubernetes', c.id]"><mat-icon>account_tree</mat-icon> Open explorer</a>
                    <button mat-stroked-button (click)="probe()" [disabled]="busy()"><mat-icon>network_check</mat-icon> Probe now</button>
                    <button mat-stroked-button class="bm-danger" (click)="remove()"><mat-icon>delete</mat-icon> Forget</button>
                  </div>
                }
              </div>

              @if (!isNew() && selected(); as c) {
                <!-- the observation point: what we know, and WHEN we last knew it -->
                <div class="bm-facts">
                  <div>
                    <span class="bm-reach bm-reach--{{ c.reachability }}"></span>
                    <strong>{{ reachLabel(c) }}</strong>
                    @if (c.unreachable_reason) { <div class="bm-why">{{ c.unreachable_reason }}</div> }
                  </div>
                  <table class="bm-table">
                    <tr><td>API server</td><td class="bm-mono">{{ c.server_url || '—' }}</td></tr>
                    <tr><td>Version</td><td class="bm-mono">{{ c.server_version || '—' }}</td></tr>
                    <tr><td>Nodes / namespaces</td><td>{{ c.node_count ?? '—' }} / {{ c.namespace_count ?? '—' }}</td></tr>
                    <tr><td>Observed</td><td>{{ observedAgo(c) }}</td></tr>
                    <tr><td>Access host</td><td>{{ c.agent_name }} <span class="bm-dim bm-mono">{{ c.agent_address }}</span></td></tr>
                  </table>
                </div>
              }

              <div class="bm-fields">
                <mat-form-field appearance="outline">
                  <mat-label>Cluster name</mat-label>
                  <input matInput [ngModel]="d.name" (ngModelChange)="patch({ name: $event })" placeholder="prod-eu" />
                </mat-form-field>
                <mat-form-field appearance="outline" class="bm-wide">
                  <mat-label>Access host (runs kubectl)</mat-label>
                  <mat-select [ngModel]="d.agent_id" (ngModelChange)="patch({ agent_id: $event })">
                    @for (h of candidates(); track h.id) {
                      <mat-option [value]="h.id">{{ h.name }} <span class="bm-dim">{{ h.address }}</span></mat-option>
                    }
                  </mat-select>
                </mat-form-field>
                <mat-form-field appearance="outline">
                  <mat-label>kubeconfig context (optional)</mat-label>
                  <input matInput [ngModel]="d.context || ''" (ngModelChange)="patch({ context: $event || null })" placeholder="current-context" />
                </mat-form-field>
                <mat-form-field appearance="outline">
                  <mat-label>kubeconfig path (optional)</mat-label>
                  <input matInput [ngModel]="d.kubeconfig_path || ''" (ngModelChange)="patch({ kubeconfig_path: $event || null })" placeholder="~/.kube/config of the agent user" />
                </mat-form-field>
                <mat-form-field appearance="outline" class="bm-wide">
                  <mat-label>Description</mat-label>
                  <input matInput [ngModel]="d.description || ''" (ngModelChange)="patch({ description: $event || null })" />
                </mat-form-field>
              </div>
              <p class="bm-hint">
                Only enrolled hosts with a reachable address are offered. Changing the access host or the context
                resets the observed facts: they belonged to the old path.
              </p>

              <div class="bm-save-row">
                <button mat-flat-button [disabled]="busy()" [bmBlocked]="blocker()" (click)="save()">
                  <mat-icon>save</mat-icon> {{ isNew() ? 'Register & probe' : 'Save' }}
                </button>
                <button mat-button (click)="cancel()">Cancel</button>
              </div>
            } @else {
              <p class="bm-dim bm-empty">Select a cluster, or register one.</p>
            }
          </mat-card-content>
        </mat-card>
      </div>
    </div>
  `,
  styles: [`
    .bm-page { padding: 24px; }
    .bm-header-row { display: flex; align-items: center; justify-content: space-between; }
    .bm-actions { display: flex; gap: 8px; flex-wrap: wrap; }
    .bm-subtitle { opacity: 0.7; margin-top: 4px; max-width: 900px; }
    .bm-split { display: grid; grid-template-columns: minmax(260px, 340px) 1fr; gap: 12px; margin-top: 12px; align-items: start; }
    @media (max-width: 900px) { .bm-split { grid-template-columns: 1fr; } }
    .bm-count { font-size: 15px; margin-bottom: 8px; }
    .bm-big { font-size: 28px; font-weight: 600; color: var(--bm-green); }
    .bm-item { padding: 7px 10px; border-radius: 8px; cursor: pointer; }
    .bm-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
    .bm-item-selected { background: color-mix(in srgb, var(--bm-green) 14%, transparent); }
    .bm-item-name { font-weight: 500; display: flex; align-items: center; gap: 8px; }
    .bm-item-meta { font-size: 12px; opacity: 0.65; margin-left: 18px; }
    .bm-reach { display: inline-block; width: 10px; height: 10px; border-radius: 50%; background: var(--bm-unknown, #888); }
    .bm-reach--reachable { background: var(--bm-green); }
    .bm-reach--unreachable { background: var(--bm-red); }
    .bm-detail-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
    .bm-detail-head h2 { margin: 0; font-size: 19px; }
    .bm-facts { margin: 12px 0 6px; padding: 10px 12px; border-radius: 8px; background: color-mix(in srgb, var(--mat-sys-on-surface) 4%, transparent); }
    .bm-facts > div { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
    .bm-why { width: 100%; font-size: 12.5px; color: var(--mat-sys-error); margin-left: 18px; }
    .bm-table { border-collapse: collapse; margin-top: 8px; font-size: var(--bm-font-table); }
    .bm-table td { padding: var(--bm-cell-py) 14px var(--bm-cell-py) 0; vertical-align: top; }
    .bm-table td:first-child { opacity: 0.6; white-space: nowrap; }
    .bm-mono { font-family: ui-monospace, monospace; }
    .bm-fields { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 14px; }
    .bm-fields mat-form-field { flex: 1 1 240px; }
    .bm-wide { flex: 2 1 420px !important; }
    .bm-hint { font-size: 12px; opacity: 0.6; }
    .bm-dim { opacity: 0.6; }
    .bm-save-row { display: flex; align-items: center; gap: 10px; margin-top: 16px; padding-top: 14px; border-top: 1px solid var(--mat-sys-outline-variant); }
    .bm-danger { color: var(--mat-sys-error); }
    .bm-empty { padding: 28px 4px; }
  `],
})
export class KubernetesClustersComponent implements OnInit {
  private svc = inject(KubernetesService);
  private agents = inject(AgentService);
  private snack = inject(MatSnackBar);

  clusters = signal<KubernetesCluster[]>([]);
  hosts = signal<Agent[]>([]);
  loading = signal(true);
  busy = signal(false);
  selectedId = signal<string | null>(null);
  isNew = signal(false);
  draft = signal<KubernetesClusterInput | null>(null);

  selected = computed(() => this.clusters().find((c) => c.id === this.selectedId()) ?? null);
  /** Enrolled hosts with an address: the only ones Bossman can ask to run kubectl. */
  candidates = computed(() =>
    this.hosts().filter((h) => h.mode !== 'cluster' && !!h.address && h.enrollment_state === 'enrolled')
      .sort((a, b) => a.name.localeCompare(b.name)));

  ngOnInit(): void { this.reload(); }

  reload(): void {
    this.loading.set(true);
    this.svc.list().subscribe({
      next: (rows) => {
        this.clusters.set(rows); this.loading.set(false);
        const id = this.selectedId();
        const again = rows.find((c) => c.id === id);
        if (id && again && !this.isNew()) this.load(again);
        else if (id && !again) { this.selectedId.set(null); this.draft.set(null); }
      },
      error: () => this.loading.set(false),
    });
    this.agents.list().subscribe((rows) => this.hosts.set(rows));
  }

  select(c: KubernetesCluster): void { this.isNew.set(false); this.selectedId.set(c.id); this.load(c); }
  private load(c: KubernetesCluster): void {
    this.draft.set({ name: c.name, agent_id: c.agent_id, context: c.context, kubeconfig_path: c.kubeconfig_path, description: c.description });
  }
  startNew(): void {
    this.isNew.set(true); this.selectedId.set(null);
    this.draft.set({ name: '', agent_id: '', context: null, kubeconfig_path: null, description: null });
  }
  cancel(): void {
    if (this.isNew()) { this.isNew.set(false); this.draft.set(null); return; }
    const c = this.selected(); if (c) this.load(c);
  }
  patch(p: Partial<KubernetesClusterInput>): void { this.draft.update((d) => (d ? { ...d, ...p } : d)); }

  reachLabel(c: KubernetesCluster): string {
    return { reachable: 'Reachable', unreachable: 'Unreachable', never: 'Never probed' }[c.reachability] ?? c.reachability;
  }
  observedAgo(c: KubernetesCluster): string {
    if (!c.observed_at) return 'never';
    return `${formatDuration((Date.now() - new Date(c.observed_at).getTime()) / 1000)} ago`;
  }

  blocker(): string | null {
    const d = this.draft();
    if (!d) return null;
    if (!d.name.trim()) return 'A name is required.';
    if (!d.agent_id) return 'Pick the access host — the host that can run kubectl against this cluster.';
    return null;
  }
  canSave(): boolean { return this.blocker() === null; }

  save(): void {
    const d = this.draft();
    if (!d || !this.canSave()) return;
    this.busy.set(true);
    const fail = (err: { status?: number; error?: { detail?: string } }) => {
      this.busy.set(false);
      const msg = err?.status === 412
        ? 'Someone else changed this cluster while you were editing. Reload to see their version — your edit was not applied.'
        : err?.error?.detail || `Save failed (HTTP ${err?.status ?? '?'})`;
      this.snack.open(String(msg), 'OK', { duration: 9000 });
    };
    if (this.isNew()) {
      this.svc.create(d).subscribe({
        next: (c) => {
          this.busy.set(false); this.isNew.set(false); this.selectedId.set(c.id);
          this.snack.open(c.reachability === 'reachable'
            ? `Registered “${c.name}”: ${c.server_version}, ${c.node_count} node(s).`
            : `Registered “${c.name}”, but it is ${c.reachability}: ${c.unreachable_reason}`, 'OK', { duration: 9000 });
          this.reload();
        },
        error: fail,
      });
    } else {
      const c = this.selected(); if (!c) return;
      this.svc.update(c.id, d, c.version).subscribe({
        next: (saved) => { this.busy.set(false); this.snack.open(`Saved “${saved.name}”.`, 'OK', { duration: 5000 }); this.reload(); },
        error: fail,
      });
    }
  }

  probe(): void {
    const c = this.selected(); if (!c) return;
    this.busy.set(true);
    this.svc.probe(c.id).subscribe({
      next: (r) => {
        this.busy.set(false);
        this.snack.open(r.reachability === 'reachable' ? `Reachable via ${r.access_host}: ${r.server_version}` : `Unreachable via ${r.access_host}: ${r.reason}`, 'OK', { duration: 9000 });
        this.reload();
      },
      error: (err) => { this.busy.set(false); this.snack.open(err?.error?.detail || 'Probe failed', 'OK', { duration: 8000 }); },
    });
  }

  remove(): void {
    const c = this.selected(); if (!c) return;
    const ref = this.snack.open(`Forget “${c.name}”? Only Bossman's registration and cache go; the cluster and ${c.agent_name} are untouched.`, 'Forget', { duration: 10000 });
    ref.onAction().subscribe(() => {
      this.svc.delete(c.id).subscribe({
        next: () => { this.selectedId.set(null); this.draft.set(null); this.snack.open(`Forgot “${c.name}”.`, 'OK', { duration: 4000 }); this.reload(); },
        error: (err) => this.snack.open(err?.error?.detail || 'Delete failed', 'OK', { duration: 8000 }),
      });
    });
  }
}
