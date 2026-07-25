import { Component, OnInit, computed, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AgentService, HelmChart, HelmRelease } from '../../core/services/agent.service';
import { ChatPlanGraphComponent, PlanGraphData } from '../chat/chat-plan-graph.component';
import { ParamFormComponent } from '../../shared/param-form/param-form.component';
import { ParamSchema } from '../../shared/param-form/param-form.types';

/**
 * Kubernetes "click-and-play" deploy (app-system increment 3 UI, plan blocks
 * 3–6). The k8s tier of the unified App model, all value-driven:
 *   pick chart → configure values → Preview (helm template → visual resource
 *   graph + rendered YAML) → Deploy (helm upgrade --install) → releases list
 *   with rollback/uninstall.
 * The SAME render path (POST /helm/render) the AI drives via MCP — the human
 * click path and the autonomous path share one authoring model. This is what
 * Rancher/KubeApps/Argo don't offer: a values-form + a visual over the RENDERED
 * manifests that actually deploys, not a read-only diagram or raw values.yaml.
 */
@Component({
  selector: 'app-kubernetes-deploy',
  standalone: true,
  imports: [FormsModule, MatIconModule, MatButtonModule, ChatPlanGraphComponent, ParamFormComponent],
  template: `
    <div class="bm-k8s">
      <!-- Deployed releases (helm list) — what's running on the cluster -->
      <section class="bm-k8s-releases">
        <div class="bm-k8s-head">
          <h3>Deployed releases</h3>
          <button mat-stroked-button (click)="loadReleases()" [disabled]="busyRel()">
            <mat-icon>refresh</mat-icon> Refresh
          </button>
        </div>
        @if (relError()) { <p class="bm-warn">No cluster reachable: {{ relError() }}</p> }
        @if (releases().length) {
          <table class="bm-table">
            <thead><tr><th>Release</th><th>Namespace</th><th>Chart</th><th>Status</th><th>Rev</th><th></th></tr></thead>
            <tbody>
              @for (r of releases(); track r.name + r.namespace) {
                <tr>
                  <td>{{ r.name }}</td><td>{{ r.namespace }}</td><td>{{ r.chart }}</td>
                  <td><span class="bm-badge" [class.ok]="r.status === 'deployed'">{{ r.status }}</span></td>
                  <td>{{ r.revision }}</td>
                  <td class="bm-actions">
                    <button mat-button (click)="rollback(r)" [disabled]="busyMut()" title="Roll back to the previous revision">Rollback</button>
                    <button mat-button color="warn" (click)="uninstall(r)" [disabled]="busyMut()">Uninstall</button>
                  </td>
                </tr>
              }
            </tbody>
          </table>
        } @else if (!busyRel() && !relError()) {
          <p class="bm-dim">No releases deployed yet.</p>
        }
      </section>

      <!-- Deploy a chart — the click-and-play flow -->
      <section class="bm-k8s-deploy">
        <h3>Deploy a chart</h3>
        <div class="bm-k8s-form">
          <label>Chart
            <input list="bm-charts" [(ngModel)]="chart" placeholder="e.g. bitnami/nginx or a local path"
                   (change)="onChartChange()" [disabled]="busyMut()" />
            <datalist id="bm-charts">
              @for (c of charts(); track c.name) { <option [value]="c.name">{{ c.version }} — {{ c.description }}</option> }
            </datalist>
          </label>
          <label>Release name <input [(ngModel)]="releaseName" placeholder="my-app" [disabled]="busyMut()" /></label>
          <label>Namespace <input [(ngModel)]="namespace" placeholder="default" [disabled]="busyMut()" /></label>
        </div>

        <div class="bm-k8s-values-head">
          <span>Values</span>
          <div class="bm-k8s-vtoggle">
            @if (hasSchema()) {
              <button mat-button [class.on]="mode() === 'form'" (click)="mode.set('form')">Form</button>
              <button mat-button [class.on]="mode() === 'yaml'" (click)="mode.set('yaml')">YAML</button>
            }
            <button mat-button (click)="loadDefaults()" [disabled]="!chart() || busyVals()">
              <mat-icon>download</mat-icon> Load chart defaults
            </button>
          </div>
        </div>
        @if (mode() === 'form' && hasSchema()) {
          <div class="bm-k8s-form-wrap">
            <app-param-form [params]="schema()" [initial]="flatValues()" (valuesChange)="onFormChange($event)" />
          </div>
        } @else {
          <textarea class="bm-k8s-values" [(ngModel)]="valuesYaml" spellcheck="false"
                    placeholder="# override the chart's values here — leave empty for defaults"
                    [disabled]="busyMut()"></textarea>
        }

        <div class="bm-k8s-buttons">
          <button mat-stroked-button (click)="preview()" [disabled]="!canDeploy() || busyRender()">
            <mat-icon>visibility</mat-icon> Preview
          </button>
          <button mat-raised-button color="primary" (click)="deploy()" [disabled]="!canDeploy() || busyMut()">
            <mat-icon>rocket_launch</mat-icon> Deploy
          </button>
        </div>

        @if (busyRender()) { <p class="bm-dim">Rendering manifests (helm template)…</p> }
        @if (renderError()) { <p class="bm-err">{{ renderError() }}</p> }
        @if (mutMsg()) { <p [class.bm-err]="!mutOk()" [class.bm-good]="mutOk()">{{ mutMsg() }}</p> }

        @if (graph(); as g) {
          <div class="bm-k8s-preview">
            <div class="bm-k8s-graph">
              <h4>Resources ({{ g.nodes.length }})</h4>
              <app-chat-plan-graph [data]="g" />
            </div>
            <div class="bm-k8s-yaml">
              <h4>Rendered manifests</h4>
              <pre>{{ rendered() }}</pre>
            </div>
          </div>
        }
      </section>
    </div>
  `,
  styles: [`
    .bm-k8s { max-width: 1100px; }
    .bm-k8s section { margin-bottom: 24px; }
    .bm-k8s-head { display: flex; align-items: center; justify-content: space-between; }
    h3 { margin: 0 0 10px; }
    h4 { margin: 0 0 6px; font-size: 12px; opacity: 0.7; text-transform: uppercase; letter-spacing: 0.04em; }
    .bm-dim { opacity: 0.6; font-size: 13px; }
    .bm-warn { color: var(--bm-gold, #b8860b); font-size: 13px; }
    .bm-err { color: var(--mat-sys-error, #c62828); }
    .bm-good { color: #1e9600; }
    .bm-table { width: 100%; border-collapse: collapse; font-size: 13px; }
    .bm-table th, .bm-table td { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-actions { text-align: right; white-space: nowrap; }
    .bm-badge { padding: 2px 8px; border-radius: 10px; background: var(--mat-sys-surface-variant); font-size: 11px; }
    .bm-badge.ok { background: rgba(30,150,0,0.18); color: #1e9600; }
    .bm-k8s-form { display: flex; gap: 14px; flex-wrap: wrap; margin-bottom: 14px; }
    .bm-k8s-form label { display: flex; flex-direction: column; gap: 4px; font-size: 12px; opacity: 0.8; flex: 1; min-width: 180px; }
    .bm-k8s-form input, .bm-k8s-values { box-sizing: border-box; padding: 8px 10px; border-radius: 8px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); font: inherit; }
    .bm-k8s-values-head { display: flex; align-items: center; justify-content: space-between; font-size: 12px; opacity: 0.8; margin-bottom: 4px; }
    .bm-k8s-vtoggle { display: flex; align-items: center; gap: 2px; }
    .bm-k8s-vtoggle .on { background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent); }
    .bm-k8s-form-wrap { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 12px 14px; }
    .bm-k8s-values { width: 100%; min-height: 180px; font-family: ui-monospace, monospace; font-size: 12.5px; resize: vertical; }
    .bm-k8s-buttons { display: flex; gap: 10px; margin: 12px 0; }
    .bm-k8s-preview { display: flex; gap: 20px; flex-wrap: wrap; margin-top: 12px; }
    .bm-k8s-graph { flex: 0 0 auto; }
    .bm-k8s-yaml { flex: 1; min-width: 320px; }
    .bm-k8s-yaml pre { max-height: 340px; overflow: auto; background: var(--mat-sys-surface-variant); padding: 12px;
      border-radius: 8px; font-size: 11.5px; margin: 0; }
  `],
})
export class KubernetesDeployComponent implements OnInit {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  ngOnInit(): void { this.loadOnce(); }

  releases = signal<HelmRelease[]>([]);
  relError = signal('');
  busyRel = signal(false);
  charts = signal<HelmChart[]>([]);

  chart = signal('');
  releaseName = signal('');
  namespace = signal('default');
  valuesYaml = signal('');

  // Typed FORM (from the chart's values.yaml, flattened server-side) vs raw YAML.
  mode = signal<'form' | 'yaml'>('form');
  schema = signal<ParamSchema>({});
  flatValues = signal<Record<string, unknown>>({});
  private formValues = signal<Record<string, unknown>>({});
  hasSchema = computed(() => Object.keys(this.schema()).length > 0);

  busyVals = signal(false);
  busyRender = signal(false);
  busyMut = signal(false);
  renderError = signal('');
  rendered = signal('');
  graph = signal<PlanGraphData | null>(null);
  mutMsg = signal('');
  mutOk = signal(false);

  canDeploy = computed(() => !!this.chart().trim() && !!this.releaseName().trim());

  private loaded = false;
  loadOnce(): void {
    if (this.loaded) return;
    this.loaded = true;
    this.loadReleases();
    this.agentService.helmCharts(this.agentId()).subscribe({ next: (r) => this.charts.set(r.charts || []), error: () => {} });
  }

  loadReleases(): void {
    this.busyRel.set(true); this.relError.set('');
    this.agentService.helmReleases(this.agentId()).subscribe({
      next: (r) => { this.busyRel.set(false); this.releases.set(r.releases || []); if (r.error) this.relError.set(r.error); },
      error: (e) => { this.busyRel.set(false); this.relError.set(e?.error?.detail || 'helm list failed'); },
    });
  }

  onChartChange(): void {
    // Suggest a release name from the chart (last path segment).
    if (!this.releaseName().trim()) {
      const seg = this.chart().split('/').pop() || '';
      this.releaseName.set(seg.replace(/[^a-z0-9-]/gi, '-').toLowerCase());
    }
  }

  loadDefaults(): void {
    this.busyVals.set(true);
    this.agentService.helmValues(this.agentId(), this.chart()).subscribe({
      next: (r) => {
        this.busyVals.set(false);
        this.valuesYaml.set(r.values_yaml || '');
        this.schema.set((r.values_schema || {}) as ParamSchema);
        this.flatValues.set(r.flat_values || {});
        this.formValues.set(r.flat_values || {});
        this.mode.set(this.hasSchema() ? 'form' : 'yaml');
      },
      error: () => this.busyVals.set(false),
    });
  }

  onFormChange(v: Record<string, unknown>): void { this.formValues.set(v); }

  /** The values payload for render/deploy: the flat form map when in form mode
   * (backend → YAML), else the raw YAML textarea. */
  private valuesBody(): { values?: Record<string, unknown>; values_yaml?: string } {
    if (this.mode() === 'form' && this.hasSchema()) return { values: this.formValues() };
    return { values_yaml: this.valuesYaml() };
  }

  preview(): void {
    this.busyRender.set(true); this.renderError.set(''); this.graph.set(null); this.rendered.set('');
    this.agentService.helmRender(this.agentId(), {
      name: this.releaseName(), chart: this.chart(), namespace: this.namespace() || 'default', ...this.valuesBody(),
    }).subscribe({
      next: (r) => {
        this.busyRender.set(false);
        if (!r.ok) { this.renderError.set(r.error || 'render failed'); return; }
        this.rendered.set(r.rendered || '');
        this.graph.set(this.toGraph(r.rendered || ''));
      },
      error: (e) => { this.busyRender.set(false); this.renderError.set(e?.error?.detail || 'render failed'); },
    });
  }

  deploy(): void {
    this.busyMut.set(true); this.mutMsg.set('');
    this.agentService.helmInstall(this.agentId(), {
      name: this.releaseName(), chart: this.chart(),
      namespace: this.namespace() || 'default', create_namespace: true, ...this.valuesBody(),
    }).subscribe({
      next: (r) => {
        this.busyMut.set(false); this.mutOk.set(r.ok);
        this.mutMsg.set(r.ok ? `Deployed "${r.name}" to ${r.namespace}.` : `Deploy failed: ${r.error}`);
        if (r.ok) this.loadReleases();
      },
      error: (e) => { this.busyMut.set(false); this.mutOk.set(false); this.mutMsg.set(e?.error?.detail || 'deploy failed'); },
    });
  }

  rollback(r: HelmRelease): void {
    this.busyMut.set(true); this.mutMsg.set('');
    this.agentService.helmRollback(this.agentId(), { name: r.name, namespace: r.namespace }).subscribe({
      next: (x) => { this.busyMut.set(false); this.mutOk.set(x.ok); this.mutMsg.set(x.ok ? `Rolled back "${r.name}".` : `Rollback failed: ${x.error}`); if (x.ok) this.loadReleases(); },
      error: (e) => { this.busyMut.set(false); this.mutOk.set(false); this.mutMsg.set(e?.error?.detail || 'rollback failed'); },
    });
  }

  uninstall(r: HelmRelease): void {
    this.busyMut.set(true); this.mutMsg.set('');
    this.agentService.helmUninstall(this.agentId(), { name: r.name, namespace: r.namespace }).subscribe({
      next: (x) => { this.busyMut.set(false); this.mutOk.set(x.ok); this.mutMsg.set(x.ok ? `Uninstalled "${r.name}".` : `Uninstall failed: ${x.error}`); if (x.ok) this.loadReleases(); },
      error: (e) => { this.busyMut.set(false); this.mutOk.set(false); this.mutMsg.set(e?.error?.detail || 'uninstall failed'); },
    });
  }

  /** Rendered multi-doc YAML → a resource graph. Nodes = each manifest
   * (kind/name); edges by the standard k8s exposure chain (Ingress → Service →
   * workload → config), inferred by kind so it works for any chart without a
   * browser-side YAML parser. */
  private toGraph(yaml: string): PlanGraphData {
    const docs = yaml.split(/^---\s*$/m);
    interface Res { id: string; kind: string; name: string; }
    const nodes: Res[] = [];
    for (const doc of docs) {
      const kind = /^kind:\s*(\S+)/m.exec(doc)?.[1];
      if (!kind) continue;
      // metadata.name — first "name:" after a "metadata:" line.
      const meta = doc.split(/^metadata:\s*$/m)[1] || doc;
      const name = /^\s+name:\s*["']?([^"'\n]+)/m.exec(meta)?.[1]?.trim() || kind.toLowerCase();
      const id = `${kind}/${name}`;
      if (!nodes.some((n) => n.id === id)) nodes.push({ id, kind, name });
    }
    const rank = (k: string): number => {
      const order = ['Ingress', 'Route', 'Service', 'Deployment', 'StatefulSet', 'DaemonSet', 'ReplicaSet', 'Pod', 'Job', 'CronJob'];
      const i = order.indexOf(k);
      return i === -1 ? 100 : i;
    };
    const support = new Set(['ConfigMap', 'Secret', 'ServiceAccount', 'PersistentVolumeClaim', 'Role', 'RoleBinding', 'ClusterRole', 'ClusterRoleBinding']);
    const chain = nodes.filter((n) => !support.has(n.kind)).sort((a, b) => rank(a.kind) - rank(b.kind));
    const edges: { from: string; to: string }[] = [];
    for (let i = 0; i < chain.length - 1; i++) edges.push({ from: chain[i].id, to: chain[i + 1].id });
    // Supporting resources hang off the first workload.
    const workload = chain.find((n) => rank(n.kind) >= 3 && rank(n.kind) < 100);
    if (workload) for (const s of nodes.filter((n) => support.has(n.kind))) edges.push({ from: workload.id, to: s.id });
    return { nodes: nodes.map((n) => ({ id: n.id, label: `${n.kind}\n${n.name}` })), edges };
  }
}
