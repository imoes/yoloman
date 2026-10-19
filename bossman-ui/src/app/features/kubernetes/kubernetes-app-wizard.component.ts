import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatSnackBar } from '@angular/material/snack-bar';
import * as yaml from 'js-yaml';
import {
  AppApplyResult, AppContainer, AppForm, AppRender, AppVolume, Inventory, KubernetesCluster, KubernetesService,
} from '../../core/services/kubernetes.service';
import { BlockedReasonDirective } from '../../shared/blocked-reason/blocked-reason.directive';

/**
 * THE APPLICATION FORM (design E6): a few answers become a correct set of objects.
 *
 * Portainer's simplification, kept: the operator never picks a kind — "how should it run" and "how is data
 * kept" derive it, and the derived kind is SAID next to the form (identity holds). Essentials are visible;
 * everything else sits under a disclosure with best-practice defaults already filled in (Restricted Pod
 * Security, a resource preset, a readiness probe on the port, the recommended labels, a Service whose
 * selector is generated from the workload). The right column is the observation point: the objects that
 * will exist, the pre-flight issues with their rule, the manifests as YAML, and after Preview the server's
 * own verdict per object. One primary action: Apply.
 */
@Component({
  selector: 'app-kubernetes-app-wizard',
  standalone: true,
  imports: [BlockedReasonDirective, FormsModule, RouterLink, MatButtonModule, MatIconModule],
  template: `
    <div class="bm-wiz">
      <header class="bm-wiz-head">
        <div>
          <div class="bm-dim bm-small"><a [routerLink]="['/kubernetes', clusterId()]">{{ cluster()?.name || 'cluster' }}</a> · Applications</div>
          <h1>{{ editing() ? 'Edit application' : 'Create application' }}</h1>
        </div>
        <div class="bm-kindbox" [class.bm-kindbox--on]="render()">
          <span class="bm-dim bm-small">will be a</span>
          <strong>{{ render()?.kind || '…' }}</strong>
          <span class="bm-small">{{ render()?.why || '' }}</span>
        </div>
      </header>

      <div class="bm-wiz-body">
        <!-- ── the form ───────────────────────────────────────────── -->
        <form class="bm-form" (submit)="$event.preventDefault()">
          <section>
            <h2>Basics</h2>
            <div class="bm-grid">
              <label>Name <input [(ngModel)]="f.name" name="name" placeholder="web" [disabled]="editing()" (ngModelChange)="dirty()" /></label>
              <label>Namespace
                <input list="ns-list" [(ngModel)]="f.namespace" name="namespace" [disabled]="editing()" (ngModelChange)="dirty()" />
                <datalist id="ns-list">@for (n of namespaces(); track n) { <option [value]="n"></option> }</datalist>
              </label>
              @if (!editing() && !namespaceExists()) {
                <label class="bm-check"><input type="checkbox" [(ngModel)]="f.create_namespace" name="create_ns" (ngModelChange)="dirty()" /> create the namespace “{{ f.namespace }}”</label>
              }
              <label class="bm-wide">Description <input [(ngModel)]="f.description" name="description" placeholder="what this application is for" (ngModelChange)="dirty()" /></label>
            </div>
            <div class="bm-grid">
              <label>How should it run?
                <select [(ngModel)]="f.run_mode" name="run_mode" (ngModelChange)="dirty()">
                  <option value="replicated">Replicated — n instances behind a Service</option>
                  <option value="every_node">On every node — one instance per node</option>
                  <option value="once">Once — run to completion</option>
                  <option value="scheduled">On a schedule — like cron</option>
                </select></label>
              @if (f.run_mode === 'replicated') {
                <label>Instances <input type="number" min="0" [(ngModel)]="f.replicas" name="replicas" [disabled]="f.hpa.enabled" (ngModelChange)="dirty()" />
                  @if (f.hpa.enabled) { <span class="bm-hint">the autoscaler owns the count</span> }</label>
                <label>How is data kept?
                  <select [(ngModel)]="f.data_mode" name="data_mode" (ngModelChange)="dirty()">
                    <option value="none">No persistent data</option>
                    <option value="shared">Shared — one volume for all instances</option>
                    <option value="per_instance">Per instance — each instance its own volume</option>
                  </select></label>
              }
              @if (f.run_mode === 'scheduled') {
                <label>Schedule (cron) <input [(ngModel)]="f.schedule!.schedule" name="schedule" placeholder="0 * * * *" (ngModelChange)="dirty()" /></label>
                <label>Time zone <input [(ngModel)]="f.schedule!.timezone" name="tz" placeholder="Europe/Berlin" (ngModelChange)="dirty()" /></label>
              }
            </div>
          </section>

          @for (c of f.containers; track $index; let i = $index) {
            <section>
              <h2>Container{{ f.containers.length > 1 ? ' ' + (i + 1) : '' }}
                @if (f.containers.length > 1) { <button type="button" class="bm-link" (click)="removeContainer(i)">remove</button> }</h2>
              <div class="bm-grid">
                <label class="bm-wide">Image <input [(ngModel)]="c.image" [name]="'image' + i" placeholder="nginx:1.27" (ngModelChange)="dirty()" />
                  @if (tagOf(c.image) === null || tagOf(c.image) === 'latest') { <span class="bm-hint bm-hint--warn">pin a tag — “latest” means “whatever the node pulls”</span> }</label>
                <label>Port <input type="number" min="1" max="65535" [ngModel]="c.ports[0]?.port ?? null" (ngModelChange)="setPort(c, $event)" [name]="'port' + i" placeholder="80" /></label>
                <label>Resources
                  <select [(ngModel)]="c.preset" [name]="'preset' + i" (ngModelChange)="dirty()">
                    <option value="small">Small — 0.1 CPU / 128 MiB (limit 0.5 CPU / 256 MiB)</option>
                    <option value="medium">Medium — 0.25 CPU / 512 MiB (limit 1 CPU / 1 GiB)</option>
                    <option value="large">Large — 1 CPU / 2 GiB (limit 2 CPU / 4 GiB)</option>
                    <option value="custom">Custom</option>
                    <option value="none">None (BestEffort — evicted first)</option>
                  </select></label>
                @if (c.preset === 'custom') {
                  <label>CPU request <input [(ngModel)]="c.cpu_request" [name]="'cpur' + i" placeholder="250m" (ngModelChange)="dirty()" /></label>
                  <label>Memory request <input [(ngModel)]="c.memory_request" [name]="'memr' + i" placeholder="512Mi" (ngModelChange)="dirty()" /></label>
                  <label>CPU limit <input [(ngModel)]="c.cpu_limit" [name]="'cpul' + i" placeholder="1" (ngModelChange)="dirty()" /></label>
                  <label>Memory limit <input [(ngModel)]="c.memory_limit" [name]="'meml' + i" placeholder="1Gi" (ngModelChange)="dirty()" /></label>
                }
                <label class="bm-wide">Environment <span class="bm-hint">one KEY=value per line</span>
                  <textarea rows="3" [ngModel]="kv(c.env)" (ngModelChange)="c.env = parseKv($event); dirty()" [name]="'env' + i"></textarea></label>
              </div>
              <details>
                <summary>Health checks, command, more</summary>
                <div class="bm-grid">
                  <label>Readiness probe
                    <select [(ngModel)]="c.readiness.kind" [name]="'rk' + i" (ngModelChange)="dirty()">
                      <option value="http">HTTP GET on the port</option><option value="tcp">TCP connect to the port</option><option value="none">none</option>
                    </select></label>
                  @if (c.readiness.kind === 'http') { <label>Readiness path <input [(ngModel)]="c.readiness.path" [name]="'rp' + i" placeholder="/" (ngModelChange)="dirty()" /></label> }
                  <label>Liveness probe
                    <select [(ngModel)]="c.liveness.kind" [name]="'lk' + i" (ngModelChange)="dirty()">
                      <option value="none">none (recommended unless the app can deadlock)</option><option value="http">HTTP GET on the port</option><option value="tcp">TCP connect</option>
                    </select></label>
                  @if (c.liveness.kind === 'http') { <label>Liveness path <input [(ngModel)]="c.liveness.path" [name]="'lp' + i" placeholder="/healthz" (ngModelChange)="dirty()" /></label> }
                  <label>Startup probe
                    <select [(ngModel)]="c.startup.kind" [name]="'sk' + i" (ngModelChange)="dirty()">
                      <option value="none">none</option><option value="http">HTTP GET (for slow starters)</option><option value="tcp">TCP connect</option>
                    </select></label>
                  <label>Command <span class="bm-hint">overrides ENTRYPOINT, space-separated</span><input [ngModel]="(c.command || []).join(' ')" (ngModelChange)="c.command = words($event); dirty()" [name]="'cmd' + i" /></label>
                  <label>Args <span class="bm-hint">overrides CMD</span><input [ngModel]="(c.args || []).join(' ')" (ngModelChange)="c.args = words($event); dirty()" [name]="'args' + i" /></label>
                  <label>Pull policy
                    <select [(ngModel)]="c.image_pull_policy" [name]="'pp' + i" (ngModelChange)="dirty()">
                      <option value="">default (IfNotPresent, Always for :latest)</option><option value="IfNotPresent">IfNotPresent</option><option value="Always">Always</option><option value="Never">Never</option>
                    </select></label>
                  <label class="bm-wide">Environment from ConfigMaps / Secrets <span class="bm-hint">one per line: configmap:name or secret:name</span>
                    <textarea rows="2" [ngModel]="refs(c.env_from || [])" (ngModelChange)="c.env_from = parseRefs($event); dirty()" [name]="'envfrom' + i"></textarea></label>
                  <label class="bm-wide">Mount ConfigMaps / Secrets as files <span class="bm-hint">one per line: configmap:name:/mount/path</span>
                    <textarea rows="2" [ngModel]="mounts(c.config_mounts || [])" (ngModelChange)="c.config_mounts = parseMounts($event); dirty()" [name]="'mounts' + i"></textarea></label>
                  <label class="bm-check"><input type="checkbox" [(ngModel)]="c.init" [name]="'init' + i" (ngModelChange)="dirty()" /> init container (runs to completion before the others)</label>
                </div>
              </details>
            </section>
          }
          <button type="button" class="bm-link" (click)="addContainer()">+ add a container</button>

          @if (f.run_mode === 'replicated' || f.run_mode === 'every_node') {
            <section>
              <h2>Reachability</h2>
              <div class="bm-grid">
                <label class="bm-check"><input type="checkbox" [(ngModel)]="f.expose.enabled" name="expose" (ngModelChange)="dirty()" /> expose with a Service</label>
                @if (f.expose.enabled) {
                  <label>Service type
                    <select [(ngModel)]="f.expose.type" name="svctype" (ngModelChange)="dirty()">
                      <option value="ClusterIP">ClusterIP — inside the cluster only</option>
                      <option value="NodePort">NodePort — on every node's IP, port 30000–32767</option>
                      <option value="LoadBalancer">LoadBalancer — needs a load-balancer controller</option>
                    </select></label>
                  <label>Service port <input type="number" [(ngModel)]="f.expose.port" name="svcport" [placeholder]="'' + (firstPort() ?? '')" (ngModelChange)="dirty()" /></label>
                  <label class="bm-check"><input type="checkbox" [(ngModel)]="f.ingress.enabled" name="ingress" (ngModelChange)="dirty()" /> publish with an Ingress (HTTP)</label>
                  @if (f.ingress.enabled) {
                    <label>Host <input [(ngModel)]="f.ingress.host" name="ihost" placeholder="shop.example.com" (ngModelChange)="dirty()" /></label>
                    <label>Path <input [(ngModel)]="f.ingress.path" name="ipath" placeholder="/" (ngModelChange)="dirty()" /></label>
                    <label>Ingress class <input list="ic-list" [(ngModel)]="f.ingress.class_name" name="iclass" (ngModelChange)="dirty()" />
                      <datalist id="ic-list">@for (c of ingressClasses(); track c) { <option [value]="c"></option> }</datalist>
                      @if (!ingressClasses().length) { <span class="bm-hint bm-hint--warn">this cluster serves no IngressClass — without a controller an Ingress has no effect</span> }</label>
                    <label>TLS secret <input [(ngModel)]="f.ingress.tls_secret" name="itls" placeholder="(existing kubernetes.io/tls secret)" (ngModelChange)="dirty()" /></label>
                  }
                }
              </div>
            </section>
          }

          @if (f.run_mode === 'replicated') {
            <section>
              <h2>Scaling & availability</h2>
              <div class="bm-grid">
                <label class="bm-check"><input type="checkbox" [(ngModel)]="f.hpa.enabled" name="hpa" (ngModelChange)="dirty()" /> autoscale on CPU</label>
                @if (f.hpa.enabled) {
                  <label>Min <input type="number" min="1" [(ngModel)]="f.hpa.min_replicas" name="hmin" (ngModelChange)="dirty()" /></label>
                  <label>Max <input type="number" min="1" [(ngModel)]="f.hpa.max_replicas" name="hmax" (ngModelChange)="dirty()" /></label>
                  <label>Target CPU % <input type="number" min="1" max="100" [(ngModel)]="f.hpa.cpu_percent" name="hcpu" (ngModelChange)="dirty()" /></label>
                }
                <label class="bm-check"><input type="checkbox" [(ngModel)]="f.pdb.enabled" name="pdb" (ngModelChange)="dirty()" /> disruption budget (keep instances up during node drains)</label>
                @if (f.pdb.enabled) { <label>Min available <input [(ngModel)]="f.pdb.min_available" name="pdbmin" placeholder="50%" (ngModelChange)="dirty()" /></label> }
                <label class="bm-check"><input type="checkbox" [(ngModel)]="f.placement.spread_across_nodes" name="spread" (ngModelChange)="dirty()" /> prefer spreading instances across nodes</label>
              </div>
              <details>
                <summary>Rollout strategy</summary>
                <div class="bm-grid">
                  <label class="bm-check"><input type="checkbox" [(ngModel)]="f.rollout!.recreate" name="recreate" (ngModelChange)="dirty()" /> Recreate (stop all, then start — brief downtime)</label>
                  @if (!f.rollout!.recreate) {
                    <label>Max surge <input [(ngModel)]="f.rollout!.max_surge" name="surge" (ngModelChange)="dirty()" /></label>
                    <label>Max unavailable <input [(ngModel)]="f.rollout!.max_unavailable" name="unavail" (ngModelChange)="dirty()" /></label>
                  }
                  <label>Progress deadline (s) <input type="number" [(ngModel)]="f.rollout!.progress_deadline_seconds" name="pds" (ngModelChange)="dirty()" /></label>
                </div>
              </details>
            </section>
          }

          @if (f.data_mode !== 'none' && f.run_mode === 'replicated') {
            <section>
              <h2>Storage</h2>
              @for (v of f.volumes; track $index; let i = $index) {
                <div class="bm-grid">
                  <label>Name <input [(ngModel)]="v.name" [name]="'vn' + i" placeholder="data" (ngModelChange)="dirty()" /></label>
                  <label>Mount path <input [(ngModel)]="v.mount_path" [name]="'vm' + i" placeholder="/var/lib/data" (ngModelChange)="dirty()" /></label>
                  <label>Size <input [(ngModel)]="v.size" [name]="'vs' + i" placeholder="5Gi" (ngModelChange)="dirty()" /></label>
                  <label>Storage class
                    <select [(ngModel)]="v.storage_class" [name]="'vc' + i" (ngModelChange)="dirty()">
                      <option value="">cluster default</option>
                      @for (sc of storageClasses(); track sc) { <option [value]="sc">{{ sc }}</option> }
                    </select></label>
                  <label>Access
                    <select [(ngModel)]="v.access_mode" [name]="'va' + i" (ngModelChange)="dirty()">
                      <option value="ReadWriteOnce">ReadWriteOnce — one node</option><option value="ReadWriteMany">ReadWriteMany — many nodes</option><option value="ReadOnlyMany">ReadOnlyMany</option>
                    </select></label>
                  <button type="button" class="bm-link" (click)="f.volumes.splice(i, 1); dirty()">remove</button>
                </div>
              }
              <button type="button" class="bm-link" (click)="addVolume()">+ add a volume</button>
            </section>
          }

          <section>
            <h2>Security</h2>
            <div class="bm-grid">
              <label>Pod Security profile
                <select [(ngModel)]="f.security.profile" name="profile" (ngModelChange)="dirty()">
                  <option value="restricted">Restricted — non-root, no privilege escalation, all capabilities dropped, seccomp (recommended)</option>
                  <option value="baseline">Baseline — no privilege escalation, default capabilities kept; the image may run as root (stock nginx needs this)</option>
                  <option value="privileged">Privileged — no restrictions</option>
                </select></label>
              <label class="bm-check"><input type="checkbox" [(ngModel)]="f.security.read_only_root_filesystem" name="rofs" (ngModelChange)="dirty()" /> read-only root filesystem
                <span class="bm-hint">best practice for images that never write — but stock nginx writes under /tmp at start and would crash; enable once the image is known</span></label>
            </div>
            <details>
              <summary>User, service account, registry</summary>
              <div class="bm-grid">
                <label>Run as user (UID) <input type="number" [(ngModel)]="f.security.run_as_user" name="uid" (ngModelChange)="dirty()" /></label>
                <label>fsGroup <input type="number" [(ngModel)]="f.security.fs_group" name="fsg" (ngModelChange)="dirty()" /></label>
                <label>Service account <input [(ngModel)]="f.security.service_account" name="sa" placeholder="default" (ngModelChange)="dirty()" /></label>
                <label>Image pull secret <input [(ngModel)]="f.security.image_pull_secret" name="ips" placeholder="(for a private registry)" (ngModelChange)="dirty()" /></label>
                <label class="bm-wide">Node selector <span class="bm-hint">one key=value per line</span>
                  <textarea rows="2" [ngModel]="kv(f.placement.node_selector)" (ngModelChange)="f.placement.node_selector = parseKv($event); dirty()" name="nodesel"></textarea></label>
                <label class="bm-wide">Extra labels <span class="bm-hint">one key=value per line; the recommended app.kubernetes.io/* labels are set for you</span>
                  <textarea rows="2" [ngModel]="kv(f.labels)" (ngModelChange)="f.labels = parseKv($event); dirty()" name="labels"></textarea></label>
                <label>Part of <input [(ngModel)]="f.part_of" name="partof" placeholder="shop" (ngModelChange)="dirty()" /></label>
                <label>Component <input [(ngModel)]="f.component" name="component" placeholder="frontend" (ngModelChange)="dirty()" /></label>
              </div>
            </details>
          </section>
        </form>

        <!-- ── the observation point ───────────────────────────────── -->
        <aside class="bm-side">
          @if (render(); as r) {
            <h3>Objects <span class="bm-dim bm-small">in apply order</span></h3>
            <ul class="bm-objects">
              @for (o of r.objects; track o.kind + o.name) {
                <li><span class="bm-dim">{{ o.kind }}</span> {{ o.name }}
                  @if (planFor(o); as p) {
                    <span class="bm-pill" [class.bm-pill--good]="(p.action === 'create' || p.action === 'update') && !p.deferred" [class.bm-pill--bad]="p.refused" [class.bm-pill--deferred]="!!p.deferred" [class.bm-pill--none]="p.action === 'noop'">{{ p.action }}</span>
                    <!-- A DEFERRED OBJECT WAS NOT VALIDATED: the server could not check it because its namespace is
                         created earlier in this set. Green would claim a verdict the API server never gave. -->
                    @if (p.deferred) { <span class="bm-deferred" [attr.title]="p.reason">not validated yet — deferred until namespace {{ p.deferred }} exists</span> }
                  }
                </li>
              }
            </ul>
            @if (r.issues.length) {
              <h3>Checks</h3>
              <ul class="bm-issues">
                @for (i of r.issues; track i.field + i.message) {
                  <li [class.bm-issue--err]="i.level === 'error'"><span class="bm-mono bm-small">{{ i.field }}</span> {{ i.message }}</li>
                }
              </ul>
            } @else { <p class="bm-small bm-dim">All pre-flight checks pass.</p> }
            @for (p of refusedPlans(); track p.kind + p.name) {
              <div class="bm-refused"><strong>{{ p.kind }} {{ p.name }} — refused by the API server</strong><div class="bm-small">{{ p.reason }}</div></div>
            }
            @for (p of warnedPlans(); track p.kind + p.name) {
              <div class="bm-warned"><strong>{{ p.kind }} {{ p.name }}</strong><div class="bm-small">{{ p.server_warnings }}</div></div>
            }
            @if (diffs().length) {
              <h3>What changes <span class="bm-dim bm-small">server-side diff</span></h3>
              @for (p of diffs(); track p.kind + p.name) {
                <details open><summary>{{ p.kind }} {{ p.name }}</summary><pre class="bm-pre bm-diff">{{ p.diff_text }}</pre></details>
              }
            }
            <h3>Manifests <span class="bm-dim bm-small">YAML, what will be applied</span></h3>
            <pre class="bm-pre">{{ yamlText() }}</pre>
          } @else {
            <p class="bm-dim">Fill in a name and an image — the objects appear here.</p>
          }
          @if (result(); as res) {
            <div class="bm-result" [class.bm-result--bad]="res.ok === false">
              @if (res.awaiting_approval) {
                <strong>Filed for approval.</strong> YOLO mode is off, so nothing was applied; a change proposal carries every object and its preview.
                <a [routerLink]="['/change-proposals']">Open proposals</a>
              } @else if (res.ok) {
                <strong>Applied.</strong>
                @for (x of res.results || []; track x.kind + x.name) { <div class="bm-small">{{ x.kind }} {{ x.name }}: generation {{ x.generation }}@if (x.warnings) { · {{ x.warnings }} }</div> }
                <a [routerLink]="['/kubernetes', clusterId()]">Back to the explorer</a>
              } @else {
                <strong>Not applied:</strong> {{ res.error }}
              }
            </div>
          }
        </aside>
      </div>

      <footer class="bm-wiz-foot">
        <span class="bm-why"><button mat-stroked-button (click)="preview()" [bmBlocked]="previewBlocked()" bmBlockedMode="tip"><mat-icon>difference</mat-icon> Preview (server dry run)</button></span>
        <span class="bm-why"><button mat-flat-button (click)="apply()" [bmBlocked]="applyBlocked()"><mat-icon>play_arrow</mat-icon> {{ editing() ? 'Apply changes' : 'Create' }}</button></span>
        @if (busy()) { <span class="bm-hint">working…</span> }
        <a mat-button [routerLink]="['/kubernetes', clusterId()]">Cancel</a>
      </footer>
    </div>
  `,
  styles: [`
    .bm-wiz { padding: 18px 24px 0; display: flex; flex-direction: column; height: calc(100vh - 100px); }
    .bm-wiz-head { display: flex; justify-content: space-between; align-items: flex-end; gap: 16px; flex-wrap: wrap; }
    .bm-wiz-head h1 { margin: 2px 0 0; font-size: 20px; }
    .bm-kindbox { display: flex; align-items: baseline; gap: 8px; padding: 8px 12px; border-radius: 10px; border: 1px solid var(--mat-sys-outline-variant); }
    .bm-kindbox--on { border-color: var(--bm-green); }
    .bm-wiz-body { display: grid; grid-template-columns: minmax(420px, 1.2fr) minmax(360px, 1fr); gap: 20px; margin-top: 14px; flex: 1; min-height: 0; }
    @media (max-width: 1100px) { .bm-wiz-body { grid-template-columns: 1fr; } }
    .bm-form { overflow-y: auto; padding-right: 8px; }
    .bm-side { overflow-y: auto; border-left: 1px solid var(--mat-sys-outline-variant); padding-left: 18px; }
    section { margin-bottom: 18px; } h2 { font-size: 14px; margin: 0 0 8px; display: flex; gap: 10px; align-items: baseline; } h3 { font-size: 13px; margin: 14px 0 6px; }
    .bm-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(230px, 1fr)); gap: 8px 14px; align-items: start; }
    label { display: flex; flex-direction: column; gap: 3px; font-size: 12.5px; opacity: 0.95; }
    label.bm-wide { grid-column: 1 / -1; } label.bm-check { flex-direction: row; align-items: center; gap: 8px; grid-column: 1 / -1; }
    input, select, textarea { padding: 6px 8px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font: inherit; font-size: 13px; }
    input[type=checkbox] { width: auto; } textarea { font-family: ui-monospace, monospace; font-size: 12px; }
    .bm-hint { font-size: 11.5px; opacity: 0.6; } .bm-hint--warn { color: var(--bm-gold, #c8a000); opacity: 1; }
    .bm-small { font-size: 12px; } .bm-dim { opacity: 0.62; } .bm-mono { font-family: ui-monospace, monospace; }
    .bm-link { background: none; border: 0; color: var(--bm-green); cursor: pointer; font: inherit; font-size: 12.5px; padding: 2px 0; }
    details { margin-top: 6px; } summary { cursor: pointer; font-size: 12.5px; opacity: 0.8; margin-bottom: 6px; }
    .bm-objects, .bm-issues { margin: 0; padding-left: 18px; font-size: 13px; } .bm-objects li, .bm-issues li { margin: 2px 0; }
    .bm-issue--err { color: var(--bm-red, #c62828); }
    .bm-pill { font-size: 11px; padding: 1px 8px; border-radius: 9px; margin-left: 6px; background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
    .bm-pill--deferred { background: color-mix(in srgb, var(--bm-gold, #b8860b) 24%, transparent); }
    .bm-deferred { display: block; font-size: 11.5px; opacity: 0.75; margin: 1px 0 0 2px; }
    .bm-pill--good { background: color-mix(in srgb, var(--bm-green, #2e7d32) 24%, transparent); } .bm-pill--bad { background: color-mix(in srgb, var(--bm-red, #c62828) 26%, transparent); } .bm-pill--none { opacity: 0.6; }
    .bm-refused { margin: 8px 0; padding: 8px 10px; border-radius: 8px; background: color-mix(in srgb, var(--bm-red, #c62828) 12%, transparent); }
    .bm-warned { margin: 8px 0; padding: 8px 10px; border-radius: 8px; background: color-mix(in srgb, var(--bm-gold, #ffc800) 14%, transparent); }
    .bm-pre { font-size: 11.5px; background: var(--mat-sys-surface-variant); padding: 10px; border-radius: 8px; max-height: 50vh; overflow: auto; margin: 0; white-space: pre; }
    .bm-diff { max-height: 240px; }
    .bm-result { margin-top: 12px; padding: 10px 12px; border-radius: 8px; background: color-mix(in srgb, var(--bm-green, #2e7d32) 14%, transparent); }
    .bm-result--bad { background: color-mix(in srgb, var(--bm-red, #c62828) 12%, transparent); }
    .bm-result a { display: inline-block; margin-top: 6px; }
    .bm-wiz-foot { display: flex; align-items: center; gap: 12px; padding: 12px 0; border-top: 1px solid var(--mat-sys-outline-variant); margin-top: 10px; }
  `],
})
export class KubernetesAppWizardComponent implements OnInit {
  private route = inject(ActivatedRoute);
  private router = inject(Router);
  private svc = inject(KubernetesService);
  private snack = inject(MatSnackBar);

  clusterId = signal('');
  cluster = signal<KubernetesCluster | null>(null);
  inventory = signal<Inventory | null>(null);
  editing = signal(false);
  busy = signal(false);
  render = signal<AppRender | null>(null);
  result = signal<AppApplyResult | null>(null);
  private renderTimer: ReturnType<typeof setTimeout> | null = null;

  /** The form. Defaults ARE the best practice; the operator only decides what the system cannot know. */
  f: AppForm = {
    name: '', namespace: 'default', description: '', run_mode: 'replicated', replicas: 1, data_mode: 'none',
    containers: [this.newContainer()], volumes: [],
    expose: { enabled: true, type: 'ClusterIP', port: null }, ingress: { enabled: false, host: '', path: '/', path_type: 'Prefix', class_name: '', tls_secret: '' },
    hpa: { enabled: false, min_replicas: 1, max_replicas: 3, cpu_percent: 80 }, pdb: { enabled: false, min_available: '50%' },
    rollout: { max_surge: '25%', max_unavailable: '25%', recreate: false, min_ready_seconds: 0, revision_history_limit: 10, progress_deadline_seconds: 600 },
    schedule: { schedule: '0 * * * *', timezone: '', concurrency_policy: 'Forbid', suspend: false, successful_history: 3, failed_history: 1, backoff_limit: 6, completions: 1, parallelism: 1, ttl_seconds_after_finished: 3600 },
    placement: { node_selector: {}, tolerations: [], spread_across_nodes: false, required_spread: false },
    security: { profile: 'restricted', run_as_user: null, run_as_group: null, fs_group: null, read_only_root_filesystem: false, service_account: '', automount_service_account_token: null, image_pull_secret: '' },
    labels: {}, annotations: {}, part_of: '', component: '', create_namespace: false,
  };

  namespaces = computed(() => (this.inventory()?.namespaces ?? []).map((n) => n.name).sort());
  storageClasses = computed(() => (this.inventory()?.storage_classes ?? []).map((s) => s.name + (s.default ? ' (default)' : '')).map((n) => n.replace(' (default)', '')));
  ingressClasses = computed(() => this.inventory()?.ingress_classes ?? []);
  refusedPlans = computed(() => (this.render()?.plans ?? []).filter((p) => p.refused));
  warnedPlans = computed(() => (this.render()?.plans ?? []).filter((p) => !p.refused && p.server_warnings));
  diffs = computed(() => (this.render()?.plans ?? []).filter((p) => p.action === 'update' && p.diff_text));
  yamlText = computed(() => (this.render()?.manifests ?? []).map((m) => yaml.dump(m, { noRefs: true, lineWidth: 120 })).join('---\n'));

  ngOnInit(): void {
    const pm = this.route.snapshot.paramMap;
    const id = pm.get('id') || '';
    this.clusterId.set(id);
    this.svc.get(id).subscribe((c) => this.cluster.set(c));
    this.svc.inventory(id).subscribe((r) => this.inventory.set(r.inventory));
    const ns = this.route.snapshot.queryParamMap.get('namespace');
    if (ns) this.f.namespace = ns;
    const ename = pm.get('name'), ens = pm.get('namespace');
    if (ename && ens) {
      this.editing.set(true);
      this.busy.set(true);
      this.svc.appGet(id, ens, ename).subscribe({
        next: (r) => { this.f = { ...this.f, ...r.form, containers: r.form.containers.length ? r.form.containers : this.f.containers }; this.busy.set(false); this.dirty(); },
        error: (e) => { this.busy.set(false); this.snack.open(this.msg(e), 'OK', { duration: 8000 }); },
      });
    }
  }

  newContainer(): AppContainer {
    return { name: '', image: '', ports: [], env: {}, preset: 'small', readiness: { kind: 'http', path: '/' }, liveness: { kind: 'none' }, startup: { kind: 'none' },
             image_pull_policy: '', init: false, command: [], args: [], env_from: [], config_mounts: [] };
  }
  addContainer(): void { this.f.containers.push(this.newContainer()); this.dirty(); }
  removeContainer(i: number): void { this.f.containers.splice(i, 1); this.dirty(); }
  addVolume(): void { this.f.volumes.push({ name: this.f.volumes.length ? `data${this.f.volumes.length + 1}` : 'data', mount_path: '/data', size: '1Gi', storage_class: '', access_mode: 'ReadWriteOnce' } as AppVolume); this.dirty(); }
  setPort(c: AppContainer, v: number | null): void { c.ports = v ? [{ port: Number(v), protocol: 'TCP' }] : []; this.dirty(); }
  firstPort(): number | null { return this.f.containers.find((c) => !c.init && c.ports.length)?.ports[0].port ?? null; }
  namespaceExists(): boolean { return !this.namespaces().length || this.namespaces().includes(this.f.namespace); }
  tagOf(image: string): string | null {
    const ref = (image || '').split('/').pop() || '';
    if (ref.includes('@')) return 'digest';
    return ref.includes(':') ? ref.split(':')[1] : null;
  }

  kv(o: Record<string, string>): string { return Object.entries(o || {}).map(([k, v]) => `${k}=${v}`).join('\n'); }
  parseKv(text: string): Record<string, string> {
    const out: Record<string, string> = {};
    for (const line of (text || '').split('\n')) { const i = line.indexOf('='); if (i > 0) out[line.slice(0, i).trim()] = line.slice(i + 1).trim(); }
    return out;
  }
  words(text: string): string[] { return (text || '').trim() ? text.trim().split(/\s+/) : []; }
  refs(list: { kind: string; name: string }[]): string { return list.map((r) => `${r.kind}:${r.name}`).join('\n'); }
  parseRefs(text: string): { kind: 'configmap' | 'secret'; name: string }[] {
    return (text || '').split('\n').map((l) => l.trim()).filter(Boolean).map((l) => { const [k, n] = l.split(':'); return { kind: (k === 'secret' ? 'secret' : 'configmap') as 'configmap' | 'secret', name: (n || '').trim() }; }).filter((r) => r.name);
  }
  mounts(list: { kind: string; name: string; mount_path: string }[]): string { return list.map((m) => `${m.kind}:${m.name}:${m.mount_path}`).join('\n'); }
  parseMounts(text: string): { kind: 'configmap' | 'secret'; name: string; mount_path: string; read_only: boolean }[] {
    return (text || '').split('\n').map((l) => l.trim()).filter(Boolean).map((l) => { const [k, n, ...p] = l.split(':'); return { kind: (k === 'secret' ? 'secret' : 'configmap') as 'configmap' | 'secret', name: (n || '').trim(), mount_path: p.join(':').trim(), read_only: true }; }).filter((m) => m.name && m.mount_path);
  }
  planFor(o: { kind: string; name: string }) { return (this.render()?.plans ?? []).find((p) => p.kind === o.kind && p.name === o.name) ?? null; }

  /** Every edit re-renders (debounced): the right column always shows the manifests the form means. */
  dirty(): void {
    this.result.set(null);
    if (this.renderTimer) clearTimeout(this.renderTimer);
    this.renderTimer = setTimeout(() => this.doRender(), 350);
  }
  private doRender(): void {
    if (!this.canPreview()) { this.render.set(null); return; }
    this.svc.appRender(this.clusterId(), this.f).subscribe({ next: (r) => this.render.set({ ...r, plans: this.render()?.plans }), error: () => {} });
  }
  canPreview(): boolean { return !!this.f.name.trim() && this.f.containers.some((c) => !!c.image.trim()); }
  blocker(): string | null {
    if (!this.f.name.trim()) return 'A name is required.';
    if (!this.f.containers.some((c) => !!c.image.trim())) return 'An image is required.';
    const errs = (this.render()?.issues ?? []).filter((i) => i.level === 'error');
    if (errs.length) return `${errs.length} check(s) must be fixed first.`;
    if (this.refusedPlans().length) return 'The API server refused an object — see the reason.';
    return null;
  }
  canApply(): boolean { return this.blocker() === null; }
  // The buttons' refusal reasons ('' = allowed): busy first, then the same checks canPreview()/blocker() make.
  previewBlocked(): string {
    if (this.busy()) return 'Working…';
    return this.canPreview() ? '' : (this.blocker() ?? '');
  }
  applyBlocked(): string {
    if (this.busy()) return 'Working…';
    return this.blocker() ?? '';
  }

  preview(): void {
    this.busy.set(true); this.result.set(null);
    this.svc.appPlan(this.clusterId(), this.f).subscribe({
      next: (r) => { this.render.set(r); this.busy.set(false); },
      error: (e) => { this.busy.set(false); this.snack.open(this.msg(e), 'OK', { duration: 9000 }); },
    });
  }
  apply(): void {
    this.busy.set(true); this.result.set(null);
    this.svc.appApply(this.clusterId(), this.f, false, true).subscribe({
      next: (r) => {
        this.busy.set(false); this.result.set(r); this.render.set({ ...r, plans: r.plans });
        if (r.ok && r.applied) this.snack.open(`Applied ${r.results?.length ?? 0} object(s).`, 'OK', { duration: 5000 });
      },
      error: (e) => { this.busy.set(false); this.snack.open(this.msg(e), 'OK', { duration: 9000 }); },
    });
  }
  private msg(e: unknown): string {
    const err = e as { error?: { detail?: unknown }; message?: string };
    const d = err?.error?.detail as { error?: string; issues?: { message: string }[] } | string | undefined;
    if (typeof d === 'string') return d;
    if (d && typeof d === 'object') return d.issues ? d.issues.map((i) => i.message).join(' · ') : JSON.stringify(d);
    return err?.message || 'request failed';
  }
}
