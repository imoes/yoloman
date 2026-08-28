import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatCardModule } from '@angular/material/card';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatSnackBar } from '@angular/material/snack-bar';
import { AggregationMode, Cluster, ClusterInput } from '../../core/models/cluster.model';
import { ClusterService } from '../../core/services/cluster.service';
import { Agent } from '../../core/models/agent.model';
import { AgentService } from '../../core/services/agent.service';
import { MonitoringService } from '../../core/services/monitoring.service';

/** The three modes, each with the sentence that says what it MEANS operationally. A mode
 * name alone ("worst") does not tell an operator what the cluster will do. */
const MODES: { value: AggregationMode; label: string; meaning: string }[] = [
  {
    value: 'worst',
    label: 'worst — any node’s problem is the cluster’s problem',
    meaning:
      'The cluster takes the worst state any node reports (OK < WARN < UNKNOWN < CRIT). Use this when every node must be healthy.',
  },
  {
    value: 'best',
    label: 'best — the cluster is fine as long as one node is fine',
    meaning:
      'The cluster takes the best state any node reports. Use this for load-balanced services where one healthy node is enough.',
  },
  {
    value: 'failover',
    label: 'failover — the primary decides, a second active node is a warning',
    meaning:
      'The cluster takes the primary node’s state. If a secondary node also reports, an otherwise OK cluster becomes WARN — in a failover cluster two active nodes is itself the news.',
  },
];

/** Host clusters (API /api/v1/clusters, aggregation services/clustering.py — a port of
 * Checkmk's cluster_mode.py).
 *
 * The backend half has always been live: the poller calls `aggregate_all_clusters` once per
 * cycle and AFTER every node (an aggregate from half-fresh node states would flap on poll
 * ordering alone), and the resulting rows go through the same debouncing, history,
 * acknowledgement, downtime and notification path as any other service. What was missing was
 * any way to CREATE one — so the whole feature was unreachable.
 *
 * What this screen has to make visible, because the model is causal:
 *  1. What each mode DOES, not just its name.
 *  2. That the preferred node matters in every mode — it decides in failover, and breaks the
 *     tie in worst/best (`pivot = primary if primary in selected else selected[0]`). Calling
 *     it "failover only" would be wrong.
 *  3. Which services a pattern actually claims — counted against the chosen nodes' real
 *     services, so a pattern that matches nothing is visible BEFORE saving.
 *  4. What the cluster reports right now (`service_states`), which is the observation point
 *     that would falsify "my patterns work".
 *
 * Called "host cluster" throughout: Kubernetes clusters and Proxmox clusters are different
 * things that already appear elsewhere in this app. */
@Component({
  selector: 'app-clusters',
  standalone: true,
  imports: [
    FormsModule, MatCardModule, MatFormFieldModule, MatInputModule, MatSelectModule,
    MatIconModule, MatButtonModule, MatCheckboxModule,
  ],
  template: `
    <div class="bm-page">
      <div class="bm-header-row">
        <h1>Host clusters</h1>
        <div class="bm-actions">
          <button mat-stroked-button (click)="reload()"><mat-icon>refresh</mat-icon> Refresh</button>
          <button mat-flat-button (click)="startNew()"><mat-icon>add</mat-icon> New cluster</button>
        </div>
      </div>
      <p class="bm-subtitle">
        A cluster <strong>is</strong> a host whose services are computed from several nodes — it
        appears in the fleet with its own problems, acknowledgements and downtime, but nothing
        polls it. Its state is recomputed once per poll cycle, after all its nodes.
      </p>

      <div class="bm-split">
        <mat-card class="bm-panel">
          <mat-card-content>
            <div class="bm-count">
              <span class="bm-big">{{ clusters().length }}</span> cluster(s)
              @if (loading()) { <span class="bm-dim">— loading…</span> }
            </div>
            @for (c of clusters(); track c.id) {
              <div class="bm-item" [class.bm-item-selected]="selectedId() === c.id" (click)="select(c)">
                <div class="bm-item-name">{{ c.name }}</div>
                <div class="bm-item-meta">
                  {{ c.aggregation_mode }} · {{ c.nodes.length }} node(s) ·
                  {{ serviceCount(c) }} service(s)
                </div>
              </div>
            } @empty {
              @if (!loading()) {
                <p class="bm-dim">
                  No clusters yet. A cluster only reports something once it has nodes and at
                  least one service pattern that matches.
                </p>
              }
            }
          </mat-card-content>
        </mat-card>

        <mat-card class="bm-panel">
          <mat-card-content>
            @if (draft(); as d) {
              <div class="bm-detail-head">
                <h2>{{ isNew() ? 'New host cluster' : d.name }}</h2>
                @if (!isNew()) {
                  <button mat-stroked-button class="bm-danger" (click)="remove()">
                    <mat-icon>delete</mat-icon> Delete
                  </button>
                }
              </div>

              <div class="bm-fields">
                <mat-form-field appearance="outline">
                  <mat-label>Cluster name</mat-label>
                  <input matInput [ngModel]="d.name" (ngModelChange)="patch({ name: $event })"
                         placeholder="db-cluster" />
                </mat-form-field>
                <mat-form-field appearance="outline" class="bm-mode">
                  <mat-label>Aggregation</mat-label>
                  <mat-select [ngModel]="d.aggregation_mode" (ngModelChange)="patch({ aggregation_mode: $event })">
                    @for (m of modes; track m.value) {
                      <mat-option [value]="m.value">{{ m.label }}</mat-option>
                    }
                  </mat-select>
                </mat-form-field>
              </div>
              <p class="bm-meaning">{{ meaning(d.aggregation_mode) }}</p>

              <!-- nodes -->
              <h3>Nodes <span class="bm-hint">the real hosts this cluster aggregates</span></h3>
              @if (candidates().length) {
                <div class="bm-nodes">
                  @for (h of candidates(); track h.id) {
                    <mat-checkbox [checked]="d.node_ids.includes(h.id)" (change)="toggleNode(h.id)">
                      {{ h.name }}
                      <span class="bm-dim">{{ h.address || 'no address' }}</span>
                    </mat-checkbox>
                  }
                </div>
              } @else {
                <p class="bm-dim">No hosts to choose from — enroll a host first.</p>
              }
              <p class="bm-hint">
                Other clusters are not offered as nodes: their own state is computed in the same
                cycle, so aggregating an aggregate would depend on the order within that cycle.
              </p>

              <!-- preferred node -->
              <h3>
                Preferred node
                <span class="bm-hint">
                  @if (d.aggregation_mode === 'failover') {
                    decides the cluster’s state
                  } @else {
                    breaks the tie when several nodes share the selected state
                  }
                </span>
              </h3>
              <mat-form-field appearance="outline" class="bm-primary">
                <mat-label>{{ d.aggregation_mode === 'failover' ? 'Primary node' : 'Preferred node (optional)' }}</mat-label>
                <mat-select [ngModel]="d.primary_node_id" (ngModelChange)="patch({ primary_node_id: $event })">
                  <mat-option [value]="null">— none (first by name) —</mat-option>
                  @for (h of chosenNodes(); track h.id) {
                    <mat-option [value]="h.id">{{ h.name }}</mat-option>
                  }
                </mat-select>
              </mat-form-field>
              @if (!chosenNodes().length) {
                <p class="bm-hint">Pick nodes first — a preferred node must be one of the cluster’s own nodes.</p>
              }
              @if (d.aggregation_mode === 'failover' && !d.primary_node_id) {
                <p class="bm-warn">
                  Without a primary, failover falls back to the worst-reporting node — the mode
                  then behaves like “worst” and the setting does nothing.
                </p>
              }

              <!-- service patterns -->
              <h3>Cluster services <span class="bm-hint">which services belong to the cluster instead of to the node</span></h3>
              @if (d.service_patterns.length) {
                <table class="bm-table">
                  <!-- The number counts SERVICE NAMES, not nodes: a pattern claims a name, and
                       three nodes all reporting "Memory" is still one claimed service. Saying
                       "matches" without that would read as a node count. -->
                  <thead><tr><th>Pattern</th><th>Claims these services</th><th></th></tr></thead>
                  <tbody>
                    @for (p of d.service_patterns; track $index) {
                      <tr>
                        <td class="bm-mono">{{ p }}</td>
                        <td [class.bm-zero]="matchesFor(p).length === 0">
                          @if (matchesFor(p).length) {
                            {{ matchesFor(p).slice(0, 4).join(', ') }}{{ matchesFor(p).length > 4 ? ', …' : '' }}
                            <span class="bm-dim">({{ matchesFor(p).length }} service(s), reported by {{ nodesReporting(p) }} of {{ d.node_ids.length }} node(s))</span>
                          } @else if (nodeServicesLoaded()) {
                            nothing — this pattern claims no service
                          } @else {
                            <span class="bm-dim">loading the nodes’ services…</span>
                          }
                        </td>
                        <td class="bm-right">
                          <button mat-icon-button (click)="removePattern($index)" aria-label="Remove pattern">
                            <mat-icon>close</mat-icon>
                          </button>
                        </td>
                      </tr>
                    }
                  </tbody>
                </table>
              } @else {
                <p class="bm-dim">
                  No patterns yet — the cluster would report nothing at all. Every service stays
                  with its node.
                </p>
              }

              @if (suggestions().length) {
                <p class="bm-hint">The chosen nodes currently report these services — click one to claim it:</p>
                <div class="bm-chips">
                  @for (s of suggestions(); track s) {
                    <button type="button" class="bm-chip" [class.bm-chip-on]="d.service_patterns.includes(s)"
                            (click)="togglePattern(s)">{{ s }}</button>
                  }
                </div>
              } @else if (d.node_ids.length && nodeServicesLoaded()) {
                <p class="bm-hint">The chosen nodes report no services yet, so there is nothing to suggest.</p>
              }
              <div class="bm-add-pattern">
                <mat-form-field appearance="outline">
                  <mat-label>Pattern (exact name, or trailing * )</mat-label>
                  <input matInput [ngModel]="newPattern()" (ngModelChange)="newPattern.set($event)"
                         placeholder="Disk *" (keyup.enter)="addPattern()" />
                </mat-form-field>
                <button mat-stroked-button [disabled]="!canAddPattern()" (click)="addPattern()">
                  <mat-icon>add</mat-icon> Add
                </button>
                @if (newPattern().trim() && d.service_patterns.includes(newPattern().trim())) {
                  <span class="bm-hint">already claimed</span>
                }
              </div>

              <div class="bm-save-row">
                <button mat-flat-button [disabled]="!canSave() || saving()" (click)="save()">
                  <mat-icon>save</mat-icon> {{ isNew() ? 'Create' : 'Save' }}
                </button>
                <button mat-button (click)="cancel()">Cancel</button>
                @if (blocker(); as b) { <span class="bm-hint">{{ b }}</span> }
              </div>

              <!-- observation point -->
              @if (!isNew() && selected(); as c) {
                <h3>What this cluster reports now <span class="bm-hint">recomputed once per poll cycle</span></h3>
                @if (serviceCount(c)) {
                  <table class="bm-table">
                    <thead><tr><th>Service</th><th>State</th></tr></thead>
                    <tbody>
                      @for (row of serviceRows(c); track row.name) {
                        <tr>
                          <td>{{ row.name }}</td>
                          <td><span class="bm-state" [class]="'bm-' + row.state.toLowerCase()">{{ row.state }}</span></td>
                        </tr>
                      }
                    </tbody>
                  </table>
                } @else {
                  <p class="bm-dim">
                    Nothing yet. Either no pattern matches a service the nodes report, or the
                    poller has not completed a cycle since the last change.
                  </p>
                }
              }
            } @else {
              <p class="bm-dim bm-empty">Select a cluster, or create one.</p>
            }
          </mat-card-content>
        </mat-card>
      </div>
    </div>
  `,
  styles: [
    `
      .bm-page { padding: 24px; }
      .bm-header-row { display: flex; align-items: center; justify-content: space-between; }
      .bm-actions { display: flex; gap: 8px; }
      .bm-subtitle { opacity: 0.7; margin-top: 4px; max-width: 900px; }
      .bm-split { display: grid; grid-template-columns: minmax(240px, 320px) 1fr; gap: 12px; margin-top: 12px; align-items: start; }
      @media (max-width: 900px) { .bm-split { grid-template-columns: 1fr; } }
      .bm-count { font-size: 15px; margin-bottom: 8px; }
      .bm-big { font-size: 28px; font-weight: 600; color: var(--bm-green); }
      .bm-item { padding: 7px 10px; border-radius: 8px; cursor: pointer; }
      .bm-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
      .bm-item-selected { background: color-mix(in srgb, var(--bm-green) 14%, transparent); }
      .bm-item-name { font-weight: 500; }
      .bm-item-meta { font-size: 12px; opacity: 0.65; }
      .bm-detail-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
      .bm-detail-head h2 { margin: 0; font-size: 19px; }
      .bm-fields { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 12px; }
      .bm-fields mat-form-field { flex: 1 1 220px; }
      .bm-mode { flex: 2 1 380px !important; }
      .bm-meaning { margin: 0 0 4px; font-size: 13px; opacity: 0.8; max-width: 820px; }
      h3 { font-size: 14px; margin: 20px 0 6px; display: flex; align-items: baseline; gap: 10px; }
      .bm-hint { font-size: 12px; font-weight: 400; opacity: 0.6; }
      .bm-warn { font-size: 12.5px; color: var(--mat-sys-error); margin: 4px 0 0; max-width: 620px; }
      .bm-nodes { display: flex; flex-direction: column; gap: 2px; max-height: 220px; overflow-y: auto; }
      .bm-nodes .bm-dim { margin-left: 8px; font-size: 12px; }
      .bm-primary { width: 100%; max-width: 320px; margin-top: 6px; }
      .bm-table { width: 100%; border-collapse: collapse; max-width: 820px; }
      .bm-table th { text-align: left; font-size: 12px; font-weight: 500; opacity: 0.6; padding: 3px 12px 3px 0; }
      .bm-table td { padding: 5px 12px 5px 0; border-top: 1px solid var(--mat-sys-outline-variant); font-size: 13.5px; }
      .bm-mono { font-family: monospace; }
      .bm-dim { opacity: 0.6; }
      .bm-right { text-align: right; }
      .bm-zero { color: var(--mat-sys-error); }
      .bm-chips { display: flex; flex-wrap: wrap; gap: 6px; margin: 6px 0 0; }
      .bm-chip { font: inherit; font-size: 12px; padding: 3px 10px; border-radius: 999px; cursor: pointer;
                 border: 1px solid var(--mat-sys-outline-variant); background: transparent; color: inherit; }
      .bm-chip:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); }
      .bm-chip-on { background: color-mix(in srgb, var(--bm-green) 22%, transparent); border-color: var(--bm-green); }
      .bm-add-pattern { display: flex; align-items: center; gap: 10px; margin-top: 12px; }
      .bm-add-pattern mat-form-field { flex: 0 1 320px; }
      .bm-save-row { display: flex; align-items: center; gap: 10px; margin-top: 20px; padding-top: 14px; border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-danger { color: var(--mat-sys-error); }
      .bm-empty { padding: 28px 4px; }
      .bm-state { font-size: 11px; font-weight: 700; padding: 1px 9px; border-radius: 999px; }
      .bm-ok { background: color-mix(in srgb, var(--bm-green) 25%, transparent); }
      .bm-warn { background: color-mix(in srgb, #ffc800 30%, transparent); color: inherit; }
      .bm-crit { background: color-mix(in srgb, var(--mat-sys-error) 30%, transparent); }
      .bm-unknown { background: color-mix(in srgb, var(--mat-sys-on-surface) 15%, transparent); }
    `,
  ],
})
export class ClustersComponent implements OnInit {
  private clusterSvc = inject(ClusterService);
  private agents = inject(AgentService);
  private monitoring = inject(MonitoringService);
  private snack = inject(MatSnackBar);

  modes = MODES;

  clusters = signal<Cluster[]>([]);
  hosts = signal<Agent[]>([]);
  loading = signal(true);
  saving = signal(false);

  selectedId = signal<string | null>(null);
  isNew = signal(false);
  draft = signal<ClusterInput | null>(null);
  newPattern = signal('');

  /** node id → the service names that node currently reports. Feeds both the suggestions
   * and the per-pattern match count, so a pattern's effect is visible before saving. */
  nodeServices = signal<Record<string, string[]>>({});
  nodeServicesLoaded = signal(false);

  selected = computed(() => this.clusters().find((c) => c.id === this.selectedId()) ?? null);

  /** Hosts offerable as nodes: not this cluster itself (the API refuses that with 422) and
   * no other cluster — see the hint in the template for why. */
  candidates = computed(() =>
    this.hosts()
      .filter((h) => h.mode !== 'cluster' && h.id !== this.selectedId())
      .sort((a, b) => a.name.localeCompare(b.name)),
  );

  chosenNodes = computed(() => {
    const ids = new Set(this.draft()?.node_ids ?? []);
    return this.hosts().filter((h) => ids.has(h.id)).sort((a, b) => a.name.localeCompare(b.name));
  });

  /** Every service name the chosen nodes report, not yet claimed. */
  suggestions = computed(() => {
    const d = this.draft();
    if (!d) return [];
    const map = this.nodeServices();
    const names = new Set<string>();
    for (const id of d.node_ids) for (const n of map[id] ?? []) names.add(n);
    return [...names].filter((n) => !d.service_patterns.includes(n)).sort();
  });

  ngOnInit(): void {
    this.reload();
  }

  reload(): void {
    this.loading.set(true);
    this.clusterSvc.list().subscribe({
      next: (rows) => {
        this.clusters.set(rows);
        this.loading.set(false);
        const id = this.selectedId();
        const again = rows.find((c) => c.id === id);
        if (id && again && !this.isNew()) this.load(again);
        else if (id && !again) { this.selectedId.set(null); this.draft.set(null); }
      },
      error: () => this.loading.set(false),
    });
    this.agents.list().subscribe((rows) => this.hosts.set(rows));
  }

  select(c: Cluster): void {
    this.isNew.set(false);
    this.selectedId.set(c.id);
    this.load(c);
  }

  private load(c: Cluster): void {
    this.draft.set({
      name: c.name,
      aggregation_mode: c.aggregation_mode,
      node_ids: c.nodes.map((n) => n.id),
      primary_node_id: c.primary_node_id,
      service_patterns: [...c.service_patterns],
    });
    this.fetchNodeServices(c.nodes.map((n) => n.id));
  }

  startNew(): void {
    this.isNew.set(true);
    this.selectedId.set(null);
    this.draft.set({ name: '', aggregation_mode: 'worst', node_ids: [], primary_node_id: null, service_patterns: [] });
    this.nodeServices.set({});
    this.nodeServicesLoaded.set(true); // nothing to load yet; no node is chosen
  }

  cancel(): void {
    if (this.isNew()) { this.isNew.set(false); this.draft.set(null); return; }
    const c = this.selected();
    if (c) this.load(c);
  }

  patch(p: Partial<ClusterInput>): void {
    this.draft.update((d) => (d ? { ...d, ...p } : d));
  }

  toggleNode(id: string): void {
    this.draft.update((d) => {
      if (!d) return d;
      const has = d.node_ids.includes(id);
      const node_ids = has ? d.node_ids.filter((x) => x !== id) : [...d.node_ids, id];
      // Dropping the node that was the preferred one must clear the preference, or the save
      // is refused with "primary_node_id must be one of the cluster's nodes" — a 422 the
      // form could have prevented.
      const primary_node_id = d.primary_node_id && node_ids.includes(d.primary_node_id) ? d.primary_node_id : null;
      return { ...d, node_ids, primary_node_id };
    });
    this.fetchNodeServices(this.draft()?.node_ids ?? []);
  }

  private fetchNodeServices(ids: string[]): void {
    if (!ids.length) { this.nodeServices.set({}); this.nodeServicesLoaded.set(true); return; }
    const missing = ids.filter((id) => this.nodeServices()[id] === undefined);
    if (!missing.length) { this.nodeServicesLoaded.set(true); return; }
    this.nodeServicesLoaded.set(false);
    let pending = missing.length;
    for (const id of missing) {
      this.monitoring.agentServices(id).subscribe({
        next: (rows) => {
          this.nodeServices.update((m) => ({ ...m, [id]: rows.map((r) => r.name) }));
          if (--pending <= 0) this.nodeServicesLoaded.set(true);
        },
        // An unreachable node is not an error here: it simply contributes no suggestions.
        error: () => {
          this.nodeServices.update((m) => ({ ...m, [id]: [] }));
          if (--pending <= 0) this.nodeServicesLoaded.set(true);
        },
      });
    }
  }

  meaning(mode: AggregationMode): string {
    return MODES.find((m) => m.value === mode)?.meaning ?? '';
  }

  /** Mirrors services/clustering.py's `owns_service`: exact name, or a trailing "*" as a
   * prefix match. Duplicated deliberately and marked as such — the count must be computed
   * before saving, and there is no endpoint that answers "what would this pattern claim?". */
  private ownsService(pattern: string, name: string): boolean {
    const p = pattern.trim();
    if (!p) return false;
    return p.endsWith('*') ? name.startsWith(p.slice(0, -1)) : name === p;
  }

  matchesFor(pattern: string): string[] {
    const d = this.draft();
    if (!d) return [];
    const map = this.nodeServices();
    const names = new Set<string>();
    for (const id of d.node_ids) for (const n of map[id] ?? []) if (this.ownsService(pattern, n)) names.add(n);
    return [...names].sort();
  }

  /** How many of the chosen nodes actually report something this pattern claims. A pattern
   * that only one node reports still aggregates — but in "worst" mode that means the other
   * nodes contribute nothing to it, which is worth seeing before saving. */
  nodesReporting(pattern: string): number {
    const d = this.draft();
    if (!d) return 0;
    const map = this.nodeServices();
    return d.node_ids.filter((id) => (map[id] ?? []).some((n) => this.ownsService(pattern, n))).length;
  }

  togglePattern(name: string): void {
    this.draft.update((d) => {
      if (!d) return d;
      const has = d.service_patterns.includes(name);
      return {
        ...d,
        service_patterns: has ? d.service_patterns.filter((p) => p !== name) : [...d.service_patterns, name],
      };
    });
  }

  canAddPattern(): boolean {
    const p = this.newPattern().trim();
    return !!p && !(this.draft()?.service_patterns ?? []).includes(p);
  }

  addPattern(): void {
    if (!this.canAddPattern()) return;
    const p = this.newPattern().trim();
    this.draft.update((d) => (d ? { ...d, service_patterns: [...d.service_patterns, p] } : d));
    this.newPattern.set('');
  }

  removePattern(index: number): void {
    this.draft.update((d) => (d ? { ...d, service_patterns: d.service_patterns.filter((_, i) => i !== index) } : d));
  }

  /** Why saving is not possible right now — the reason is shown next to the disabled
   * button, rather than leaving the operator to guess. */
  blocker(): string | null {
    const d = this.draft();
    if (!d) return null;
    if (!d.name.trim()) return 'A name is required.';
    if (!d.node_ids.length) return 'Pick at least one node — a cluster with no nodes can never report anything.';
    if (!d.service_patterns.length) return 'Claim at least one service, otherwise the cluster stays empty.';
    return null;
  }

  canSave(): boolean {
    return this.blocker() === null;
  }

  serviceCount(c: Cluster): number {
    return Object.keys(c.service_states || {}).length;
  }

  serviceRows(c: Cluster): { name: string; state: string }[] {
    return Object.entries(c.service_states || {})
      .map(([name, state]) => ({ name, state }))
      .sort((a, b) => a.name.localeCompare(b.name));
  }

  save(): void {
    const d = this.draft();
    if (!d || !this.canSave()) return;
    this.saving.set(true);
    const fail = (err: { status?: number; error?: { detail?: string } }) => {
      this.saving.set(false);
      const msg =
        err?.status === 412
          ? 'Someone else changed this cluster while you were editing. Reload to see their version — your edit was not applied.'
          : err?.error?.detail || `Save failed (HTTP ${err?.status ?? '?'})`;
      this.snack.open(msg, 'OK', { duration: 9000 });
    };
    if (this.isNew()) {
      this.clusterSvc.create(d).subscribe({
        next: (c) => {
          this.saving.set(false);
          this.isNew.set(false);
          this.selectedId.set(c.id);
          this.snack.open(`Created “${c.name}”. Its services appear after the next poll cycle.`, 'OK', { duration: 6000 });
          this.reload();
        },
        error: fail,
      });
    } else {
      const c = this.selected();
      if (!c) return;
      this.clusterSvc.update(c.id, d, c.version).subscribe({
        next: (saved) => {
          this.saving.set(false);
          this.snack.open(`Saved “${saved.name}”. Aggregation follows on the next poll cycle.`, 'OK', { duration: 6000 });
          this.reload();
        },
        error: fail,
      });
    }
  }

  remove(): void {
    const c = this.selected();
    if (!c) return;
    const ref = this.snack.open(
      `Delete “${c.name}”? Its ${this.serviceCount(c)} aggregated service(s) go with it. The ${c.nodes.length} node(s) stay untouched.`,
      'Delete',
      { duration: 10000 },
    );
    ref.onAction().subscribe(() => {
      this.clusterSvc.delete(c.id).subscribe({
        next: () => {
          this.selectedId.set(null);
          this.draft.set(null);
          this.snack.open(`Deleted “${c.name}”.`, 'OK', { duration: 4000 });
          this.reload();
        },
        error: (err) => this.snack.open(err?.error?.detail || 'Delete failed', 'OK', { duration: 8000 }),
      });
    });
  }
}
